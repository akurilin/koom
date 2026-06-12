@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
@preconcurrency import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case displayNotFound
    case writerFailed(String)
    case recorderNotRunning
    case microphoneNotFound

    var errorDescription: String? {
        switch self {
        case .displayNotFound:
            return "The selected display could not be found."
        case .writerFailed(let reason):
            return reason
        case .recorderNotRunning:
            return "The recorder is not currently running."
        case .microphoneNotFound:
            return "The selected microphone could not be found."
        }
    }
}

final class ScreenRecorder: NSObject, @unchecked Sendable {
    typealias RuntimeIssueHandler = @Sendable (String) -> Void
    /// Asks the owner to allocate the next segment file and call
    /// `rollToNextSegment(to:)` back with it. The recorder keeps
    /// writing to the current segment until that call arrives, so
    /// the round trip costs no media.
    typealias SegmentRolloverHandler = @Sendable (ScreenRecorder) -> Void

    struct Configuration {
        let displayID: CGDirectDisplayID
        let microphoneID: String?
        let outputURL: URL
        /// Media time after which the recorder finishes the current
        /// segment file and continues on a fresh one without stopping
        /// capture, so a crash loses at most one segment. nil records
        /// the whole session into a single file.
        let segmentDuration: CMTime?
        let expectedFrameRate: Int
    }

    private struct MicrophoneConfiguration {
        let writerSettings: [String: Any]
        let sourceFormatHint: CMFormatDescription
    }

    private let configuration: Configuration
    private let onRuntimeIssue: RuntimeIssueHandler?
    private let onSegmentRolloverNeeded: SegmentRolloverHandler?
    private let sampleQueue = DispatchQueue(label: "koom.recording.samples")

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var hasStartedSession = false
    private var timeline = RecorderTimelineController()
    private var backpressureMonitor = RecorderBackpressureMonitor()
    private var isFinishing = false
    private var isStopping = false
    private var isPaused = false
    private var isRollingOver = false
    private var hasLoggedWriterFailure = false
    private var hasReportedRuntimeIssue = false
    private var hasDumpedDiagnostics = false
    private var diagnostics = RecorderDiagnosticsCollector()

    // Captured at start() so rollover can build identically-configured
    // writers for follow-up segments.
    private var videoDimensions: (width: Int, height: Int)?
    private var microphoneWriterConfiguration: MicrophoneConfiguration?
    private var currentSegmentURL: URL
    /// Rolled-over writers finalize off the sample queue; stop() waits
    /// on this group so every segment file is complete before assembly.
    private let segmentFinishGroup = DispatchGroup()

    init(
        configuration: Configuration,
        onRuntimeIssue: RuntimeIssueHandler? = nil,
        onSegmentRolloverNeeded: SegmentRolloverHandler? = nil
    ) {
        self.configuration = configuration
        self.onRuntimeIssue = onRuntimeIssue
        self.onSegmentRolloverNeeded = onSegmentRolloverNeeded
        self.currentSegmentURL = configuration.outputURL
    }

    func start() async throws {
        AppLog.info(
            "Recorder starting. Display ID: \(configuration.displayID), microphone: \(configuration.microphoneID ?? "none"), frame rate: \(configuration.expectedFrameRate) fps, output: \(configuration.outputURL.path)"
        )
        if FileManager.default.fileExists(atPath: configuration.outputURL.path) {
            try FileManager.default.removeItem(at: configuration.outputURL)
        }

        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard
            let display = shareableContent.displays.first(where: {
                $0.displayID == configuration.displayID
            })
        else {
            throw RecorderError.displayNotFound
        }

        var microphoneConfiguration: MicrophoneConfiguration?
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = display.width
        streamConfiguration.height = display.height
        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(configuration.expectedFrameRate)
        )
        streamConfiguration.queueDepth = 6
        streamConfiguration.showsCursor = true
        streamConfiguration.capturesAudio = false

        if let microphoneID = configuration.microphoneID {
            microphoneConfiguration = try Self.microphoneConfiguration(
                for: microphoneID
            )
            streamConfiguration.captureMicrophone = true
            streamConfiguration.microphoneCaptureDeviceID = microphoneID
        }

        let contentFilter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let stream = SCStream(
            filter: contentFilter,
            configuration: streamConfiguration,
            delegate: self
        )
        try stream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: sampleQueue
        )
        if configuration.microphoneID != nil {
            try stream.addStreamOutput(
                self,
                type: .microphone,
                sampleHandlerQueue: sampleQueue
            )
        }

        self.videoDimensions = (display.width, display.height)
        self.microphoneWriterConfiguration = microphoneConfiguration
        if let microphoneConfiguration {
            AppLog.info(
                "Using microphone writer settings: \(Self.formatSettingsDescription(microphoneConfiguration.writerSettings))"
            )
        }

        let segmentWriter = try makeSegmentWriter(
            outputURL: configuration.outputURL,
            width: display.width,
            height: display.height,
            microphoneConfiguration: microphoneConfiguration
        )
        self.writer = segmentWriter.writer
        self.videoInput = segmentWriter.videoInput
        self.audioInput = segmentWriter.audioInput
        self.currentSegmentURL = configuration.outputURL

        self.stream = stream
        diagnostics.start(
            recordingStartedAt: Date(),
            microphoneUniqueID: configuration.microphoneID
        )

        do {
            try await stream.startCapture()
            AppLog.info("Recorder capture started.")
        } catch {
            try? await stream.stopCapture()
            diagnostics.stop()
            AppLog.error("Recorder failed to start: \(error.localizedDescription)")
            throw error
        }
    }

    func pause() {
        sampleQueue.async {
            self.isPaused = true
            self.timeline.pause()
            AppLog.info("Recorder paused.")
        }
    }

    func resume() {
        sampleQueue.async {
            self.isPaused = false
            self.timeline.resume()
            AppLog.info("Recorder resumed.")
        }
    }

    /// Stops capture and finalizes the current segment. Returns the
    /// current segment's URL; with rollover there may be earlier,
    /// already-finalized segments that the session manifest tracks.
    func stop(discardOutput: Bool) async throws -> URL {
        guard writer != nil else {
            throw RecorderError.recorderNotRunning
        }

        isStopping = true
        AppLog.info("Recorder stopping. Discard output: \(discardOutput)")
        try? await stream?.stopCapture()
        await drainSampleQueue()

        // Snapshot the writer state on the sample queue: setting
        // isFinishing there guarantees no rollover can swap the writer
        // after this point.
        let (finalWriter, finalSegmentURL, segmentHasMedia): (AVAssetWriter?, URL, Bool) = await withCheckedContinuation { continuation in
            sampleQueue.async {
                self.isFinishing = true
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                continuation.resume(
                    returning: (self.writer, self.currentSegmentURL, self.hasStartedSession)
                )
            }
        }

        if let finalWriter {
            if segmentHasMedia {
                await finalWriter.finishWriting()
            } else {
                // A writer whose session never started (stop landed
                // before the first sample, e.g. right after a rollover)
                // cannot finishWriting; cancel it and drop the empty
                // file so the session's other segments still finalize.
                finalWriter.cancelWriting()
                try? FileManager.default.removeItem(at: finalSegmentURL)
                AppLog.info(
                    "Discarded empty segment \(finalSegmentURL.lastPathComponent) at stop."
                )
            }
        }

        // Wait for any rolled-over segment still finalizing in the
        // background before the caller inspects or assembles files.
        await withCheckedContinuation { continuation in
            segmentFinishGroup.notify(queue: sampleQueue) {
                continuation.resume()
            }
        }

        defer {
            stream = nil
            self.writer = nil
            videoInput = nil
            audioInput = nil
            hasStartedSession = false
            timeline = RecorderTimelineController()
            backpressureMonitor = RecorderBackpressureMonitor()
            isFinishing = false
            isStopping = false
            isPaused = false
            isRollingOver = false
            videoDimensions = nil
            microphoneWriterConfiguration = nil
            hasLoggedWriterFailure = false
            hasReportedRuntimeIssue = false
            hasDumpedDiagnostics = false
            diagnostics.stop()
            diagnostics = RecorderDiagnosticsCollector()
        }

        if discardOutput {
            try? FileManager.default.removeItem(at: finalSegmentURL)
            AppLog.info("Discarded recording segment at \(finalSegmentURL.path)")
            return finalSegmentURL
        }

        if !segmentHasMedia || finalWriter?.status == .completed {
            AppLog.info("Recorder finished writing \(finalSegmentURL.path)")
            return finalSegmentURL
        }

        let reason = Self.writerFailureDescription(finalWriter)
        AppLog.error("Recorder failed to finalize: \(reason)")
        throw RecorderError.writerFailed(reason)
    }

    // MARK: - Segment rollover

    /// Called on the sample queue after each appended video frame.
    /// Triggering on video (not audio) guarantees the segment being
    /// closed contains video, which the assembler requires of every
    /// segment it stitches.
    private func requestSegmentRolloverIfNeeded(retimedVideoPTS: CMTime) {
        guard let segmentDuration = configuration.segmentDuration,
            !isRollingOver, !isFinishing, !isStopping,
            CMTIME_IS_VALID(retimedVideoPTS),
            CMTimeCompare(retimedVideoPTS, segmentDuration) >= 0
        else {
            return
        }

        isRollingOver = true
        onSegmentRolloverNeeded?(self)
    }

    /// Completes a rollover started by `onSegmentRolloverNeeded`: the
    /// new writer starts before the old one finalizes, so capture and
    /// appends continue gaplessly. The fresh timeline restarts each
    /// segment at PTS zero, which is what the assembler's
    /// back-to-back concatenation expects.
    func rollToNextSegment(to outputURL: URL) {
        sampleQueue.async {
            guard self.isRollingOver, !self.isFinishing, !self.isStopping,
                let oldWriter = self.writer,
                let dimensions = self.videoDimensions
            else {
                return
            }

            let oldVideoInput = self.videoInput
            let oldAudioInput = self.audioInput
            let finishedSegmentURL = self.currentSegmentURL

            do {
                let next = try self.makeSegmentWriter(
                    outputURL: outputURL,
                    width: dimensions.width,
                    height: dimensions.height,
                    microphoneConfiguration: self.microphoneWriterConfiguration
                )
                self.writer = next.writer
                self.videoInput = next.videoInput
                self.audioInput = next.audioInput
                self.currentSegmentURL = outputURL
                self.hasStartedSession = false
                var freshTimeline = RecorderTimelineController()
                if self.isPaused {
                    freshTimeline.pause()
                }
                self.timeline = freshTimeline
                self.diagnostics.noteSegmentRollover()

                oldVideoInput?.markAsFinished()
                oldAudioInput?.markAsFinished()
                self.segmentFinishGroup.enter()
                // Safe to touch the writer from the @Sendable completion:
                // it runs only after the writer has finished all work.
                nonisolated(unsafe) let finishingWriter = oldWriter
                oldWriter.finishWriting {
                    if finishingWriter.status == .completed {
                        AppLog.info(
                            "Finished segment \(finishedSegmentURL.lastPathComponent)."
                        )
                    } else {
                        AppLog.error(
                            "Segment \(finishedSegmentURL.lastPathComponent) failed to finalize after rollover: \(Self.writerFailureDescription(finishingWriter))"
                        )
                    }
                    self.segmentFinishGroup.leave()
                }
                AppLog.info(
                    "Rolled over to segment \(outputURL.lastPathComponent)."
                )
            } catch {
                // Losing rollover is better than losing the recording:
                // keep appending to the current (now oversized) segment.
                AppLog.error(
                    "Segment rollover failed; continuing on \(finishedSegmentURL.lastPathComponent): \(error.localizedDescription)"
                )
            }
            self.isRollingOver = false
        }
    }

    private func makeSegmentWriter(
        outputURL: URL,
        width: Int,
        height: Int,
        microphoneConfiguration: MicrophoneConfiguration?
    ) throws -> (
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        audioInput: AVAssetWriterInput?
    ) {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.videoSettings(
                width: width,
                height: height,
                frameRate: configuration.expectedFrameRate
            )
        )
        videoInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput) else {
            throw RecorderError.writerFailed(
                "koom could not add a video track to the recording."
            )
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let microphoneConfiguration {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: microphoneConfiguration.writerSettings,
                sourceFormatHint: microphoneConfiguration.sourceFormatHint
            )
            input.expectsMediaDataInRealTime = true

            guard writer.canAdd(input) else {
                throw RecorderError.writerFailed(
                    "koom could not add an audio track to the recording."
                )
            }
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw RecorderError.writerFailed(
                writer.error?.localizedDescription
                    ?? "koom could not start writing the movie file."
            )
        }

        return (writer, videoInput, audioInput)
    }

    private func append(sampleBuffer: CMSampleBuffer, mediaType: AVMediaType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        guard !isFinishing else { return }

        if writer?.status == .failed {
            // Record the event for forensics before bailing.
            if mediaType == .audio {
                diagnostics.recordAudioBuffer(
                    sampleBuffer,
                    sourcePTS: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                    retimedPTS: .invalid,
                    outcome: .writerAlreadyFailed
                )
            }
            emitDiagnosticsIfFirstFailure(
                reason: "writer.status == .failed on entry",
                failingTrack: mediaType == .audio ? .audio : .video,
                failingBuffer: sampleBuffer
            )
            reportRuntimeIssue(
                "The movie writer failed mid-recording. \(Self.writerFailureDescription(writer))"
            )
            return
        }

        switch mediaType {
        case .video:
            let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard
                let retimedBuffer = prepareRetimedBuffer(
                    sampleBuffer,
                    track: .video
                )
            else {
                return
            }
            appendPreparedBuffer(
                retimedBuffer,
                to: videoInput,
                track: .video,
                originalSourceBuffer: sampleBuffer,
                originalSourcePTS: sourcePTS
            )
            requestSegmentRolloverIfNeeded(
                retimedVideoPTS: CMSampleBufferGetPresentationTimeStamp(retimedBuffer)
            )
        case .audio:
            appendAudioSample(sampleBuffer)
        default:
            return
        }
    }

    /// Full audio path with diagnostics instrumentation on every
    /// branch. Each drop/backpressure/success/failure is fed to
    /// the diagnostics collector so the ring buffer captures the
    /// whole pattern leading up to a failure.
    private func appendAudioSample(_ sampleBuffer: CMSampleBuffer) {
        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timelineDecision = prepareAudioTimelineDecision(sampleBuffer, sourcePTS: sourcePTS)

        guard let retimedBuffer = timelineDecision.retimedBuffer else {
            // Already recorded the drop inside prepareAudioTimelineDecision.
            return
        }

        let retimedPTS = CMSampleBufferGetPresentationTimeStamp(retimedBuffer)

        guard let input = audioInput else {
            diagnostics.recordAudioBuffer(
                retimedBuffer,
                sourcePTS: sourcePTS,
                retimedPTS: retimedPTS,
                outcome: .droppedInvalidRetime
            )
            return
        }

        guard input.isReadyForMoreMediaData else {
            diagnostics.recordAudioBuffer(
                retimedBuffer,
                sourcePTS: sourcePTS,
                retimedPTS: retimedPTS,
                outcome: .backpressure
            )
            handleInputBackpressure(
                whileAppending: .audio,
                sampleBuffer: retimedBuffer
            )
            return
        }

        backpressureMonitor.noteSuccessfulAppend(for: .audio)

        if input.append(retimedBuffer) {
            diagnostics.recordAudioBuffer(
                retimedBuffer,
                sourcePTS: sourcePTS,
                retimedPTS: retimedPTS,
                outcome: .appended
            )
        } else {
            diagnostics.recordAudioBuffer(
                retimedBuffer,
                sourcePTS: sourcePTS,
                retimedPTS: retimedPTS,
                outcome: .appendFailed
            )
            logWriterFailureIfNeeded(
                whileAppending: .audio,
                sampleBuffer: retimedBuffer
            )
            emitDiagnosticsIfFirstFailure(
                reason: "audio input.append() returned false",
                failingTrack: .audio,
                failingBuffer: retimedBuffer,
                failingSourcePTS: sourcePTS,
                failingRetimedPTS: retimedPTS
            )
            reportRuntimeIssue(
                "Failed appending audio sample. \(Self.writerFailureDescription(writer))"
            )
        }
    }

    /// Runs the timeline decision for an audio buffer and records
    /// any drop in diagnostics. Returns the retimed buffer (or nil
    /// if the buffer was dropped).
    private func prepareAudioTimelineDecision(
        _ sampleBuffer: CMSampleBuffer,
        sourcePTS: CMTime
    ) -> (retimedBuffer: CMSampleBuffer?, dropReason: RecorderSampleDropReason?) {
        let decision = timeline.processSample(sourcePTS: sourcePTS, track: .audio)

        if decision.shouldStartSession, !hasStartedSession {
            writer?.startSession(atSourceTime: .zero)
            hasStartedSession = true
            AppLog.info(
                "Anchored recording session at source PTS \(sourcePTS.seconds) via audio track."
            )
        }

        if decision.didAnchorTrack {
            let offsetSeconds = decision.sessionOffset.map(\.seconds) ?? 0
            AppLog.info(
                "Anchored audio track at source PTS \(sourcePTS.seconds), session offset \(offsetSeconds)."
            )
        }

        if decision.shouldLogFirstSampleFormat {
            AppLog.info(
                "First audio sample format: \(Self.describeSampleBufferFormat(sampleBuffer))"
            )
        }

        guard decision.shouldAppend, let offset = decision.retimeOffset else {
            let outcome: AudioAppendOutcome
            switch decision.dropReason {
            case .nonMonotonic:
                let currentPTS = CMTimeSubtract(sourcePTS, decision.retimeOffset ?? .zero)
                AppLog.error(
                    "Dropped non-monotonic audio sample. currentPTS=\(currentPTS.seconds)"
                )
                outcome = .droppedNonMonotonic
            case .paused:
                outcome = .droppedPaused
            case .waitingForSessionAnchor:
                outcome = .droppedWaitingForAnchor
            case .none:
                outcome = .droppedInvalidRetime
            }
            diagnostics.recordAudioBuffer(
                sampleBuffer,
                sourcePTS: sourcePTS,
                retimedPTS: .invalid,
                outcome: outcome
            )
            return (nil, decision.dropReason)
        }

        let retimedBuffer = sampleBuffer.retimed(bySubtracting: offset)
        if retimedBuffer == nil {
            diagnostics.recordAudioBuffer(
                sampleBuffer,
                sourcePTS: sourcePTS,
                retimedPTS: .invalid,
                outcome: .droppedInvalidRetime
            )
            reportRuntimeIssue(
                "koom could not retime an audio sample buffer while recording."
            )
        }

        return (retimedBuffer, nil)
    }

    private func appendPreparedBuffer(
        _ sampleBuffer: CMSampleBuffer,
        to input: AVAssetWriterInput?,
        track: RecorderTrack,
        originalSourceBuffer: CMSampleBuffer,
        originalSourcePTS: CMTime
    ) {
        guard let input else { return }

        guard input.isReadyForMoreMediaData else {
            handleInputBackpressure(
                whileAppending: track,
                sampleBuffer: sampleBuffer
            )
            return
        }

        backpressureMonitor.noteSuccessfulAppend(for: track)

        if input.append(sampleBuffer) {
            if track == .video {
                diagnostics.recordVideoAppend(success: true)
            }
        } else {
            if track == .video {
                diagnostics.recordVideoAppend(success: false)
            }
            logWriterFailureIfNeeded(
                whileAppending: track,
                sampleBuffer: sampleBuffer
            )
            emitDiagnosticsIfFirstFailure(
                reason: "\(track.rawValue) input.append() returned false",
                failingTrack: track,
                failingBuffer: sampleBuffer,
                failingSourcePTS: originalSourcePTS,
                failingRetimedPTS: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            )
            reportRuntimeIssue(
                "Failed appending \(track.rawValue) sample. \(Self.writerFailureDescription(writer))"
            )
        }
    }

    private func handleInputBackpressure(
        whileAppending track: RecorderTrack,
        sampleBuffer: CMSampleBuffer
    ) {
        let decision = backpressureMonitor.noteBackpressure(for: track)
        if decision.shouldLog {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let ptsDescription = CMTIME_IS_VALID(pts) ? "\(pts.seconds)" : "invalid"
            switch track {
            case .audio:
                AppLog.error(
                    "Audio writer backpressure at PTS \(ptsDescription). consecutiveDrops=\(decision.consecutiveAudioBackpressureSamples)"
                )
            case .video:
                AppLog.error(
                    "Dropped \(decision.droppedVideoSamples) video sample(s) because the writer was not ready. latestPTS=\(ptsDescription)"
                )
            }
        }

        if decision.shouldReportRuntimeIssue {
            reportRuntimeIssue(
                "The microphone track fell behind while recording. koom stopped the recording to preserve the captured portion."
            )
        }
    }

    private func prepareRetimedBuffer(
        _ sampleBuffer: CMSampleBuffer,
        track: RecorderTrack
    ) -> CMSampleBuffer? {
        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let decision = timeline.processSample(sourcePTS: sourcePTS, track: track)

        if decision.shouldStartSession, !hasStartedSession {
            writer?.startSession(atSourceTime: .zero)
            hasStartedSession = true
            AppLog.info(
                "Anchored recording session at source PTS \(sourcePTS.seconds) via \(track.rawValue) track."
            )
        }

        if decision.didAnchorTrack {
            let offsetSeconds = decision.sessionOffset.map(\.seconds) ?? 0
            AppLog.info(
                "Anchored \(track.rawValue) track at source PTS \(sourcePTS.seconds), session offset \(offsetSeconds)."
            )
        }

        if decision.shouldLogFirstSampleFormat {
            AppLog.info(
                "First \(track.rawValue) sample format: \(Self.describeSampleBufferFormat(sampleBuffer))"
            )
        }

        guard decision.shouldAppend, let offset = decision.retimeOffset else {
            if decision.dropReason == .nonMonotonic {
                let currentPTS = CMTimeSubtract(sourcePTS, decision.retimeOffset ?? .zero)
                AppLog.error(
                    "Dropped non-monotonic \(track.rawValue) sample. currentPTS=\(currentPTS.seconds)"
                )
            }
            return nil
        }

        let retimedBuffer = sampleBuffer.retimed(bySubtracting: offset)
        if retimedBuffer == nil {
            reportRuntimeIssue(
                "koom could not retime a \(track.rawValue) sample buffer while recording."
            )
        }

        return retimedBuffer
    }

    private func reportRuntimeIssue(_ message: String) {
        guard !hasReportedRuntimeIssue else { return }
        hasReportedRuntimeIssue = true
        AppLog.error(message)
        onRuntimeIssue?(message)
    }

    /// Dump the diagnostics collector's forensic report to
    /// `AppLog.error`. Gated so we only emit once per recording —
    /// the first failure is the interesting one; cascading
    /// failures after the writer is already dead would just drown
    /// out the original signal.
    private func emitDiagnosticsIfFirstFailure(
        reason: String,
        failingTrack: RecorderTrack?,
        failingBuffer: CMSampleBuffer?,
        failingSourcePTS: CMTime? = nil,
        failingRetimedPTS: CMTime? = nil
    ) {
        guard !hasDumpedDiagnostics else { return }
        hasDumpedDiagnostics = true
        diagnostics.emitFailureReport(
            reason: reason,
            failingTrack: failingTrack,
            failingBuffer: failingBuffer,
            failingBufferSourcePTS: failingSourcePTS,
            failingBufferRetimedPTS: failingRetimedPTS,
            writer: writer,
            audioInput: audioInput,
            videoInput: videoInput
        )
    }

    private func logWriterFailureIfNeeded(
        whileAppending track: RecorderTrack,
        sampleBuffer: CMSampleBuffer
    ) {
        guard !hasLoggedWriterFailure else { return }
        hasLoggedWriterFailure = true

        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsDescription =
            CMTIME_IS_VALID(sourcePTS) ? "\(sourcePTS.seconds)" : "invalid"
        AppLog.error(
            "Failed appending \(track.rawValue) sample at retimed PTS \(ptsDescription). \(Self.writerFailureDescription(writer))"
        )
    }

    private func drainSampleQueue() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async {
                continuation.resume()
            }
        }
    }

    private static func videoSettings(
        width: Int,
        height: Int,
        frameRate: Int
    ) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(width * height * 4, 8_000_000),
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: max(frameRate * 2, 1),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
    }

    private static func microphoneConfiguration(
        for deviceID: String
    ) throws -> MicrophoneConfiguration {
        guard
            let device = CaptureDeviceCatalog.microphones().first(where: {
                $0.uniqueID == deviceID
            })
        else {
            throw RecorderError.microphoneNotFound
        }

        let normalizedAudioFormat = normalizedAudioFormat(for: device)
        return MicrophoneConfiguration(
            writerSettings: audioWriterSettings(
                sampleRate: normalizedAudioFormat.sampleRate,
                channelCount: normalizedAudioFormat.channelCount
            ),
            sourceFormatHint: device.activeFormat.formatDescription
        )
    }

    private static func normalizedAudioFormat(
        for device: AVCaptureDevice
    ) -> (sampleRate: Double, channelCount: Int) {
        let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
            device.activeFormat.formatDescription
        )
        let sampleRate =
            streamDescription.map {
                let reportedSampleRate =
                    $0.pointee.mSampleRate > 0 ? $0.pointee.mSampleRate : 48_000
                return reportedSampleRate > 48_000 ? 48_000 : reportedSampleRate
            } ?? 48_000
        let channelCount =
            streamDescription.map {
                max(1, Int($0.pointee.mChannelsPerFrame))
            } ?? 1
        return (sampleRate, min(channelCount, 2))
    }

    private static func audioWriterSettings(
        sampleRate: Double,
        channelCount: Int
    ) -> [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: channelCount == 1 ? 96_000 : 128_000,
        ]

        if let channelLayoutData = channelLayoutData(for: channelCount) {
            settings[AVChannelLayoutKey] = channelLayoutData
        }

        return settings
    }

    private static func channelLayoutData(for channelCount: Int) -> Data? {
        guard var channelLayout = channelLayout(for: channelCount) else {
            return nil
        }

        // AudioChannelLayout is a variable-length C struct. For tag-based
        // mono/stereo layouts with zero explicit channel descriptions, the
        // payload ends before the trailing flexible array member.
        let baseLayoutSize =
            MemoryLayout<AudioChannelLayout>.size
            - MemoryLayout<AudioChannelDescription>.size

        return Data(
            bytes: &channelLayout,
            count: baseLayoutSize
        )
    }

    private static func channelLayout(
        for channelCount: Int
    ) -> AudioChannelLayout? {
        let layoutTag: AudioChannelLayoutTag
        switch channelCount {
        case 1:
            layoutTag = kAudioChannelLayoutTag_Mono
        case 2:
            layoutTag = kAudioChannelLayoutTag_Stereo
        default:
            return nil
        }

        return AudioChannelLayout(
            mChannelLayoutTag: layoutTag,
            mChannelBitmap: AudioChannelBitmap(rawValue: 0),
            mNumberChannelDescriptions: 0,
            mChannelDescriptions: AudioChannelDescription(
                mChannelLabel: kAudioChannelLabel_Unknown,
                mChannelFlags: AudioChannelFlags(rawValue: 0),
                mCoordinates: (0, 0, 0)
            )
        )
    }

    private static func writerFailureDescription(
        _ writer: AVAssetWriter?
    ) -> String {
        guard let writer else {
            return "Writer unavailable."
        }

        let baseDescription =
            writer.error?.localizedDescription
            ?? "The operation could not be completed."
        let nsError = writer.error as NSError?
        let domain = nsError.map { "domain=\($0.domain)" } ?? "domain=unknown"
        let code = nsError.map { "code=\($0.code)" } ?? "code=unknown"
        let underlying = nsError?.userInfo[NSUnderlyingErrorKey] as? NSError
        let underlyingDescription =
            underlying.map {
                " underlyingDomain=\($0.domain) underlyingCode=\($0.code) underlyingDescription=\($0.localizedDescription)"
            } ?? ""

        return
            "status=\(writer.status.rawValue) \(domain) \(code) \(baseDescription)\(underlyingDescription)"
    }

    fileprivate static func formatSettingsDescription(
        _ settings: [String: Any]
    ) -> String {
        settings
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
    }

    private static func describeSampleBufferFormat(
        _ sampleBuffer: CMSampleBuffer
    ) -> String {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Audio
        else {
            return "non-audio format"
        }

        let streamDescription =
            CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        let sampleRate = streamDescription?.pointee.mSampleRate ?? 0
        let channelCount = streamDescription?.pointee.mChannelsPerFrame ?? 0
        let formatIDValue = streamDescription?.pointee.mFormatID ?? 0
        let formatID = Self.fourCCDescription(formatIDValue)

        return
            "formatID=\(formatID) sampleRate=\(sampleRate) channels=\(channelCount)"
    }

    private static func fourCCDescription(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]

        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) {
            return String(decoding: bytes, as: UTF8.self)
        }

        return "0x" + bytes.map { String(format: "%02X", $0) }.joined()
    }
}

extension ScreenRecorder: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        switch outputType {
        case .screen:
            // SCK emits idle/blank frames with no pixel data when the
            // screen content hasn't changed. Appending one to the
            // writer kills it with the undocumented -16122, so only
            // complete frames are writable.
            guard Self.isCompleteVideoFrame(sampleBuffer) else {
                diagnostics.recordSkippedVideoFrame()
                return
            }
            append(sampleBuffer: sampleBuffer, mediaType: .video)
        case .microphone:
            append(sampleBuffer: sampleBuffer, mediaType: .audio)
        default:
            return
        }
    }

    private static func isCompleteVideoFrame(
        _ sampleBuffer: CMSampleBuffer
    ) -> Bool {
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
            return false
        }
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
            let statusRawValue = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRawValue)
        else {
            return false
        }
        return status == .complete
    }
}

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        sampleQueue.async {
            guard !self.isStopping else { return }

            let nsError = error as NSError
            self.emitDiagnosticsIfFirstFailure(
                reason: "SCStream.didStopWithError: \(nsError.domain) code=\(nsError.code)",
                failingTrack: nil,
                failingBuffer: nil
            )
            self.reportRuntimeIssue(
                "ScreenCaptureKit stopped the recording unexpectedly. domain=\(nsError.domain) code=\(nsError.code) \(error.localizedDescription)"
            )
        }
    }
}

// Internal (not private) so the retiming tests can drive synthetic
// buffers through the exact code path production uses.
extension CMSampleBuffer {
    func retimed(bySubtracting offset: CMTime) -> CMSampleBuffer? {
        var timingEntryCount = 0
        CMSampleBufferGetSampleTimingInfoArray(
            self,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingEntryCount
        )

        guard timingEntryCount > 0 else {
            return self
        }

        var timings = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid
            ),
            count: timingEntryCount
        )

        CMSampleBufferGetSampleTimingInfoArray(
            self,
            entryCount: timingEntryCount,
            arrayToFill: &timings,
            entriesNeededOut: &timingEntryCount
        )

        for index in timings.indices {
            if CMTIME_IS_VALID(timings[index].presentationTimeStamp) {
                timings[index].presentationTimeStamp = CMTimeSubtract(
                    timings[index].presentationTimeStamp,
                    offset
                )
            }

            if CMTIME_IS_VALID(timings[index].decodeTimeStamp) {
                timings[index].decodeTimeStamp = CMTimeSubtract(
                    timings[index].decodeTimeStamp,
                    offset
                )
            }
        }

        var retimedBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: self,
            sampleTimingEntryCount: timingEntryCount,
            sampleTimingArray: &timings,
            sampleBufferOut: &retimedBuffer
        )

        guard status == noErr else { return nil }
        return retimedBuffer
    }
}
