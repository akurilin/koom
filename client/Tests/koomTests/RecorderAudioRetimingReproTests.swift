import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import XCTest

@testable import koom

/// Headless reproduction harness for the intermittent -16341 recording
/// failure (AVAssetWriter fails during a movie-fragment flush a few
/// seconds into a recording; see ~/Library/Logs/koom/koom.log).
///
/// Both tests replay the exact audio/video anchor PTS pairs observed in
/// real sessions — video timestamps in nanoseconds (timescale 1e9, as
/// ScreenCaptureKit delivers screen frames), audio in samples (timescale
/// 48000) — through the production timeline + retiming code, with no
/// capture hardware, permissions, or human in the loop.
///
/// `testRetimedAudioTimelineIsSampleContiguous` runs by default as the
/// regression guard for the retiming fix (offset converted once into
/// the track's timescale; see RecorderTimelineController).
///
/// The writer-replay tests never reproduced -16341 synthetically (the
/// failure needed live SCK buffers), and production no longer uses
/// movieFragmentInterval at all — segment rollover replaced it. They
/// are kept as historical probes, gated behind KOOM_RECORDER_REPRO=1
/// because they are slow. Run with:
///
///   KOOM_RECORDER_REPRO=1 swift test --package-path client \
///     --filter RecorderAudioRetimingReproTests
final class RecorderAudioRetimingReproTests: XCTestCase {

    /// Anchor PTS pairs from every recording session in koom.log as of
    /// 2026-06-12 (grep "Anchored (video|audio) track"). The logged
    /// values are seconds; production timescales (1e9 video / 48000
    /// audio) make them exactly recoverable by rounding.
    /// `failedAtRetimedPTS` is the retimed PTS of the failing audio
    /// append for sessions that died with -16341, nil for clean ones.
    private struct LoggedSession {
        let name: String
        let videoAnchorSeconds: Double
        let audioAnchorSeconds: Double
        let failedAtRetimedPTS: Double?

        var videoAnchorNanoseconds: Int64 {
            Int64((videoAnchorSeconds * 1_000_000_000).rounded())
        }

        var audioAnchorSamples: Int64 {
            Int64((audioAnchorSeconds * 48_000).rounded())
        }
    }

    private static let loggedSessions: [LoggedSession] = [
        .init(name: "04-10 16:46", videoAnchorSeconds: 272435.0157365, audioAnchorSeconds: 272435.0534583333, failedAtRetimedPTS: nil),
        .init(name: "04-10 17:40", videoAnchorSeconds: 275692.356537708, audioAnchorSeconds: 275692.6014583333, failedAtRetimedPTS: 4.255587292),
        .init(name: "04-10 17:46", videoAnchorSeconds: 276045.107183458, audioAnchorSeconds: 276045.13491666666, failedAtRetimedPTS: nil),
        .init(name: "04-10 18:56", videoAnchorSeconds: 280222.72642775, audioAnchorSeconds: 280222.7311458333, failedAtRetimedPTS: nil),
        .init(name: "04-10 18:57", videoAnchorSeconds: 280256.64472525, audioAnchorSeconds: 280256.6655416667, failedAtRetimedPTS: nil),
        .init(name: "04-11 18:46", videoAnchorSeconds: 20427.083933708, audioAnchorSeconds: 20427.23829166667, failedAtRetimedPTS: 10.159691292),
        .init(name: "04-11 19:05", videoAnchorSeconds: 21546.907823625, audioAnchorSeconds: 21546.92202083333, failedAtRetimedPTS: nil),
        .init(name: "04-11 19:15", videoAnchorSeconds: 22139.571025041, audioAnchorSeconds: 22139.591875, failedAtRetimedPTS: 4.223516626),
        .init(name: "04-11 19:30", videoAnchorSeconds: 23070.26821875, audioAnchorSeconds: 23070.300166666668, failedAtRetimedPTS: nil),
        .init(name: "04-11 19:31", videoAnchorSeconds: 23141.638506458, audioAnchorSeconds: 23141.656375, failedAtRetimedPTS: nil),
        .init(name: "04-13 22:36", videoAnchorSeconds: 53484.952518625, audioAnchorSeconds: 53484.985125, failedAtRetimedPTS: nil),
        .init(name: "04-13 22:50a", videoAnchorSeconds: 54290.435758, audioAnchorSeconds: 54290.472604166665, failedAtRetimedPTS: 4.207512833),
        .init(name: "04-13 22:50b", videoAnchorSeconds: 54304.135685416, audioAnchorSeconds: 54304.16289583333, failedAtRetimedPTS: nil),
        .init(name: "06-12 10:01", videoAnchorSeconds: 451976.332814625, audioAnchorSeconds: 451976.5485208333, failedAtRetimedPTS: nil),
        .init(name: "06-12 10:05", videoAnchorSeconds: 452235.256197916, audioAnchorSeconds: 452235.29795833334, failedAtRetimedPTS: nil),
        .init(name: "06-12 10:06a", videoAnchorSeconds: 452268.747656875, audioAnchorSeconds: 452268.77222916664, failedAtRetimedPTS: nil),
        .init(name: "06-12 10:06b", videoAnchorSeconds: 452306.522421625, audioAnchorSeconds: 452306.5466041667, failedAtRetimedPTS: 6.178849208),
        .init(name: "06-12 10:07a", videoAnchorSeconds: 452317.039023, audioAnchorSeconds: 452317.0616875, failedAtRetimedPTS: 4.225331167),
        .init(name: "06-12 10:07b", videoAnchorSeconds: 452343.755523458, audioAnchorSeconds: 452343.7899375, failedAtRetimedPTS: nil),
        .init(name: "06-12 10:37", videoAnchorSeconds: 454112.744404791, audioAnchorSeconds: 454112.77427083335, failedAtRetimedPTS: nil),
        .init(name: "06-12 10:41", videoAnchorSeconds: 454378.842804166, audioAnchorSeconds: 454378.8758541667, failedAtRetimedPTS: nil),
        .init(name: "06-12 10:54", videoAnchorSeconds: 455155.188105416, audioAnchorSeconds: 455155.2140208333, failedAtRetimedPTS: 4.217915417),
    ]

    private static let audioSamplesPerBuffer: Int64 = 512
    private static let audioSampleRate: Int32 = 48_000
    private static let videoFrameRate = 15

    private func skipUnlessOptedIn() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KOOM_RECORDER_REPRO"] == "1",
            "Repro harness for the known -16341 recorder bug; opt in with KOOM_RECORDER_REPRO=1"
        )
    }

    // MARK: - Test 1: retimed audio timeline must be sample-contiguous

    /// The retimed audio timeline must satisfy
    /// pts[n+1] == pts[n] + duration[n] EXACTLY (as CMTimes, not
    /// seconds). Production retimes audio (timescale 48000) against a
    /// video-anchored session offset (timescale 1e9); per-buffer
    /// cross-timescale subtraction used to round, leaking ~1ns gaps.
    /// The timeline now converts the offset into the track's timescale
    /// once at anchor time; this guards that property.
    func testRetimedAudioTimelineIsSampleContiguous() throws {
        let format = try Self.makeAudioFormatDescription()
        let bufferDuration = CMTime(
            value: Self.audioSamplesPerBuffer,
            timescale: Self.audioSampleRate
        )

        for session in Self.loggedSessions {
            var timeline = RecorderTimelineController()
            // Video anchors the session first, exactly as in the logs.
            _ = timeline.processSample(
                sourcePTS: CMTime(
                    value: session.videoAnchorNanoseconds,
                    timescale: 1_000_000_000
                ),
                track: .video
            )

            var expectedPTS: CMTime?
            var discontinuities = 0
            var firstDiscontinuity: String?

            for n in 0..<200 {
                let sourcePTS = CMTime(
                    value: session.audioAnchorSamples
                        + Int64(n) * Self.audioSamplesPerBuffer,
                    timescale: Self.audioSampleRate
                )
                let decision = timeline.processSample(
                    sourcePTS: sourcePTS,
                    track: .audio
                )
                guard decision.shouldAppend, let offset = decision.retimeOffset
                else {
                    XCTFail("\(session.name): timeline dropped audio buffer \(n)")
                    return
                }

                let buffer = try Self.makeAudioBuffer(
                    presentationTimeStamp: sourcePTS,
                    formatDescription: format
                )
                guard let retimed = buffer.retimed(bySubtracting: offset) else {
                    XCTFail("\(session.name): retime failed for buffer \(n)")
                    return
                }

                let retimedPTS = CMSampleBufferGetPresentationTimeStamp(retimed)
                if let expectedPTS, CMTimeCompare(retimedPTS, expectedPTS) != 0 {
                    discontinuities += 1
                    if firstDiscontinuity == nil {
                        firstDiscontinuity = """
                            buffer \(n): expected \(expectedPTS.value)/\(expectedPTS.timescale), \
                            got \(retimedPTS.value)/\(retimedPTS.timescale)
                            """
                    }
                }
                expectedPTS = CMTimeAdd(retimedPTS, bufferDuration)
            }

            XCTAssertEqual(
                discontinuities,
                0,
                "\(session.name): retimed audio timeline is not sample-contiguous; first: \(firstDiscontinuity ?? "-")"
            )
        }
    }

    // MARK: - Test 2: full fragmented-writer replay of logged sessions

    /// Drives a real AVAssetWriter configured exactly like production
    /// (.mp4, movieFragmentInterval=2s, same AAC/H.264 settings) with
    /// synthetic media replaying each logged session's anchors, faster
    /// than realtime. Sessions whose anchors killed real recordings
    /// should reproduce the -16341 fragment-flush failure here.
    func testFragmentedWriterReplayOfLoggedAnchors() async throws {
        try skipUnlessOptedIn()

        var reproduced: [String] = []
        var report: [String] = []

        for session in Self.loggedSessions {
            let outcome = try await replay(session: session, mediaSeconds: 11.0)
            let expected =
                session.failedAtRetimedPTS.map {
                    "failed @\(String(format: "%.3f", $0)) in production"
                } ?? "clean in production"
            report.append("\(session.name): \(outcome.summary) (\(expected))")
            if case .writerFailed = outcome {
                reproduced.append("\(session.name): \(outcome.summary)")
            }
        }

        print("=== Fragmented writer replay results ===")
        for line in report { print(line) }

        XCTAssertTrue(
            reproduced.isEmpty,
            "AVAssetWriter fragment failure reproduced without capture hardware:\n"
                + reproduced.joined(separator: "\n")
        )
    }

    /// Same replay as above but paced in wall-clock realtime with
    /// production-sized video frames, so the writer's background
    /// fragment flush races the appends the way it does in a real
    /// recording. Only replays the sessions that failed in production.
    /// Takes ~11s per session (~80s total).
    func testFragmentedWriterRealtimeReplayOfFailedAnchors() async throws {
        try skipUnlessOptedIn()

        var reproduced: [String] = []
        var report: [String] = []

        for session in Self.loggedSessions where session.failedAtRetimedPTS != nil {
            let outcome = try await replay(
                session: session,
                mediaSeconds: 11.0,
                pacing: .realtime,
                width: 3008,
                height: 1692
            )
            report.append(
                "\(session.name): \(outcome.summary) (failed @\(String(format: "%.3f", session.failedAtRetimedPTS!)) in production)"
            )
            if case .writerFailed = outcome {
                reproduced.append("\(session.name): \(outcome.summary)")
            }
        }

        print("=== Realtime fragmented writer replay results ===")
        for line in report { print(line) }

        XCTAssertTrue(
            reproduced.isEmpty,
            "AVAssetWriter fragment failure reproduced in realtime replay:\n"
                + reproduced.joined(separator: "\n")
        )
    }

    private enum ReplayPacing {
        /// Append as fast as the writer accepts media.
        case fastForward
        /// Sleep until each buffer's wall-clock due time, mirroring live
        /// capture delivery.
        case realtime
    }

    private enum ReplayOutcome {
        case completed
        case writerFailed(retimedPTS: Double, code: Int, underlyingCode: Int?)

        var summary: String {
            switch self {
            case .completed:
                return "completed"
            case .writerFailed(let pts, let code, let underlying):
                let underlyingText = underlying.map(String.init) ?? "none"
                return
                    "writer FAILED @\(String(format: "%.3f", pts)) code=\(code) underlying=\(underlyingText)"
            }
        }
    }

    /// Video-only variant: live soak runs with the mic deselected die
    /// with -16341 at the 6.0s fragment boundary 5/5, so unlike the
    /// audio+video race this may be deterministic enough to reproduce
    /// synthetically.
    func testFragmentedWriterVideoOnlyReplay() async throws {
        try skipUnlessOptedIn()

        var reproduced: [String] = []
        var report: [String] = []

        for session in Self.loggedSessions.prefix(5) {
            let outcome = try await replay(
                session: session,
                mediaSeconds: 11.0,
                pacing: .realtime,
                width: 3008,
                height: 1692,
                includeAudio: false
            )
            report.append("\(session.name) video-only: \(outcome.summary)")
            if case .writerFailed = outcome {
                reproduced.append("\(session.name): \(outcome.summary)")
            }
        }

        print("=== Video-only fragmented writer replay results ===")
        for line in report { print(line) }

        XCTAssertTrue(
            reproduced.isEmpty,
            "Video-only fragment failure reproduced synthetically:\n"
                + reproduced.joined(separator: "\n")
        )
    }

    private func replay(
        session: LoggedSession,
        mediaSeconds: Double,
        pacing: ReplayPacing = .fastForward,
        width: Int = 640,
        height: Int = 360,
        includeAudio: Bool = true
    ) async throws -> ReplayOutcome {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("koom-repro-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        // Same value AppModel passes to the recorder.
        writer.movieFragmentInterval = CMTime(seconds: 2.0, preferredTimescale: 600)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: ScreenRecorder.videoSettings(
                width: width,
                height: height,
                frameRate: Self.videoFrameRate
            )
        )
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        let audioFormat = try Self.makeAudioFormatDescription()
        var audioInput: AVAssetWriterInput?
        if includeAudio {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: ScreenRecorder.audioWriterSettings(
                    sampleRate: 48_000,
                    channelCount: 2
                ),
                sourceFormatHint: audioFormat
            )
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw RecorderError.writerFailed("startWriting failed in replay")
        }

        var timeline = RecorderTimelineController()
        var hasStartedSession = false
        let pixelBuffer = try Self.makePixelBuffer(width: width, height: height)
        let videoFormat = try Self.makeVideoFormatDescription(for: pixelBuffer)

        let videoFrameCount = Int(mediaSeconds * Double(Self.videoFrameRate))
        let audioBufferCount =
            includeAudio
            ? Int(
                mediaSeconds * Double(Self.audioSampleRate)
                    / Double(Self.audioSamplesPerBuffer)
            )
            : 0
        var nextVideoFrame = 0
        var nextAudioBuffer = 0
        let replayStartedAt = Date()

        func videoSourcePTS(_ n: Int) -> CMTime {
            CMTime(
                value: session.videoAnchorNanoseconds
                    + Int64((Double(n) * 1e9 / Double(Self.videoFrameRate)).rounded()),
                timescale: 1_000_000_000
            )
        }

        func audioSourcePTS(_ n: Int) -> CMTime {
            CMTime(
                value: session.audioAnchorSamples
                    + Int64(n) * Self.audioSamplesPerBuffer,
                timescale: Self.audioSampleRate
            )
        }

        // Interleave the two tracks in source-PTS order, mirroring the
        // single serial sample queue production appends from.
        while nextVideoFrame < videoFrameCount || nextAudioBuffer < audioBufferCount {
            let videoPTS =
                nextVideoFrame < videoFrameCount
                ? videoSourcePTS(nextVideoFrame) : nil
            let audioPTS =
                nextAudioBuffer < audioBufferCount
                ? audioSourcePTS(nextAudioBuffer) : nil

            let isVideoNext: Bool
            switch (videoPTS, audioPTS) {
            case (let video?, let audio?):
                isVideoNext = CMTimeCompare(video, audio) <= 0
            case (.some, nil):
                isVideoNext = true
            default:
                isVideoNext = false
            }

            let track: RecorderTrack = isVideoNext ? .video : .audio
            let sourcePTS = isVideoNext ? videoPTS! : audioPTS!
            if isVideoNext { nextVideoFrame += 1 } else { nextAudioBuffer += 1 }

            if pacing == .realtime {
                let dueTime = replayStartedAt.addingTimeInterval(
                    sourcePTS.seconds - session.videoAnchorSeconds
                )
                let delay = dueTime.timeIntervalSinceNow
                if delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1e9))
                }
            }

            let decision = timeline.processSample(sourcePTS: sourcePTS, track: track)
            if decision.shouldStartSession, !hasStartedSession {
                writer.startSession(atSourceTime: .zero)
                hasStartedSession = true
            }
            guard decision.shouldAppend, let offset = decision.retimeOffset else {
                continue
            }

            let buffer: CMSampleBuffer
            if isVideoNext {
                buffer = try Self.makeVideoBuffer(
                    pixelBuffer: pixelBuffer,
                    formatDescription: videoFormat,
                    presentationTimeStamp: sourcePTS
                )
            } else {
                buffer = try Self.makeAudioBuffer(
                    presentationTimeStamp: sourcePTS,
                    formatDescription: audioFormat
                )
            }
            guard let retimed = buffer.retimed(bySubtracting: offset) else {
                throw RecorderError.couldNotCreateRetimedBuffer
            }

            // We feed faster than realtime, so unlike production we must
            // wait for readiness instead of dropping — dropping would
            // change the media content and invalidate the replay.
            guard let input = isVideoNext ? videoInput : audioInput else {
                continue
            }
            let readyDeadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData, writer.status == .writing {
                if Date() > readyDeadline {
                    throw RecorderError.writerFailed(
                        "\(session.name): input never became ready"
                    )
                }
                usleep(2_000)
            }

            if writer.status == .failed || !input.append(retimed) {
                let retimedPTS = CMSampleBufferGetPresentationTimeStamp(retimed)
                let outcome = Self.failureOutcome(
                    writer: writer,
                    retimedPTS: retimedPTS.seconds
                )
                writer.cancelWriting()
                return outcome
            }
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()

        if writer.status == .completed {
            return .completed
        }
        return Self.failureOutcome(writer: writer, retimedPTS: mediaSeconds)
    }

    private static func failureOutcome(
        writer: AVAssetWriter,
        retimedPTS: Double
    ) -> ReplayOutcome {
        let error = writer.error as NSError?
        let underlying = error?.userInfo[NSUnderlyingErrorKey] as? NSError
        return .writerFailed(
            retimedPTS: retimedPTS,
            code: error?.code ?? 0,
            underlyingCode: underlying?.code
        )
    }

    // MARK: - Synthetic media factories

    /// Float32 interleaved stereo 48kHz — the exact source format the
    /// failure diagnostics recorded (lpcm, flags 0x9, 8 bytes/frame).
    private static func makeAudioFormatDescription() throws -> CMAudioFormatDescription {
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        // Header-only layout: 12 bytes, before the flexible array member.
        let layoutSize =
            MemoryLayout<AudioChannelLayout>.size
            - MemoryLayout<AudioChannelDescription>.size

        var formatDescription: CMAudioFormatDescription?
        let status = withUnsafePointer(to: &layout) { layoutPointer in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &streamDescription,
                layoutSize: layoutSize,
                layout: layoutPointer,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            )
        }
        guard status == noErr, let formatDescription else {
            throw RecorderError.writerFailed(
                "Could not create audio format description (status \(status))"
            )
        }
        return formatDescription
    }

    /// 512 frames of silence matching the diagnostics' buffer shape
    /// (4096 bytes, one timing entry, PTS at timescale 48000).
    private static func makeAudioBuffer(
        presentationTimeStamp: CMTime,
        formatDescription: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        let byteCount = Int(audioSamplesPerBuffer) * 8
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else {
            throw RecorderError.writerFailed("CMBlockBuffer creation failed (\(status))")
        }
        CMBlockBufferFillDataBytes(
            with: 0,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )

        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(audioSamplesPerBuffer),
            presentationTimeStamp: presentationTimeStamp,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw RecorderError.writerFailed("Audio sample buffer creation failed (\(status))")
        }
        return sampleBuffer
    }

    private static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw RecorderError.writerFailed("CVPixelBuffer creation failed (\(status))")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0x80, CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    private static func makeVideoFormatDescription(
        for pixelBuffer: CVPixelBuffer
    ) throws -> CMVideoFormatDescription {
        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw RecorderError.writerFailed("Video format description failed (\(status))")
        }
        return formatDescription
    }

    /// SCK screen frames carry a nanosecond PTS and no duration; mirror
    /// that so the retiming path sees the same timing shape.
    private static func makeVideoBuffer(
        pixelBuffer: CVPixelBuffer,
        formatDescription: CMVideoFormatDescription,
        presentationTimeStamp: CMTime
    ) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw RecorderError.writerFailed("Video sample buffer creation failed (\(status))")
        }
        return sampleBuffer
    }
}
