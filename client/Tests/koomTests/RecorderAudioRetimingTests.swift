import AudioToolbox
import CoreMedia
import XCTest

@testable import koom

/// Regression guard for the audio retiming fix: the recorder retimes
/// audio (timescale 48000) against a session offset usually anchored
/// by video (timescale 1e9). Per-buffer cross-timescale subtraction
/// used to round, leaking ~1ns gaps; `RecorderTimelineController` now
/// converts the offset into the track's timescale once at anchor time,
/// and this test holds it to exact sample contiguity.
///
/// The anchor pairs replay real sessions logged in koom.log as of
/// 2026-06-12 (grep "Anchored (video|audio) track"); several of them
/// belonged to recordings that died with the -16341 fragment-flush
/// failure movie fragments used to cause. The logged values are
/// seconds; production timescales make them exactly recoverable by
/// rounding.
final class RecorderAudioRetimingTests: XCTestCase {

    private struct LoggedSession {
        let name: String
        let videoAnchorSeconds: Double
        let audioAnchorSeconds: Double

        var videoAnchorNanoseconds: Int64 {
            Int64((videoAnchorSeconds * 1_000_000_000).rounded())
        }

        var audioAnchorSamples: Int64 {
            Int64((audioAnchorSeconds * 48_000).rounded())
        }
    }

    private static let loggedSessions: [LoggedSession] = [
        .init(name: "04-10 16:46", videoAnchorSeconds: 272435.0157365, audioAnchorSeconds: 272435.0534583333),
        .init(name: "04-10 17:40", videoAnchorSeconds: 275692.356537708, audioAnchorSeconds: 275692.6014583333),
        .init(name: "04-10 17:46", videoAnchorSeconds: 276045.107183458, audioAnchorSeconds: 276045.13491666666),
        .init(name: "04-10 18:56", videoAnchorSeconds: 280222.72642775, audioAnchorSeconds: 280222.7311458333),
        .init(name: "04-10 18:57", videoAnchorSeconds: 280256.64472525, audioAnchorSeconds: 280256.6655416667),
        .init(name: "04-11 18:46", videoAnchorSeconds: 20427.083933708, audioAnchorSeconds: 20427.23829166667),
        .init(name: "04-11 19:05", videoAnchorSeconds: 21546.907823625, audioAnchorSeconds: 21546.92202083333),
        .init(name: "04-11 19:15", videoAnchorSeconds: 22139.571025041, audioAnchorSeconds: 22139.591875),
        .init(name: "04-11 19:30", videoAnchorSeconds: 23070.26821875, audioAnchorSeconds: 23070.300166666668),
        .init(name: "04-11 19:31", videoAnchorSeconds: 23141.638506458, audioAnchorSeconds: 23141.656375),
        .init(name: "04-13 22:36", videoAnchorSeconds: 53484.952518625, audioAnchorSeconds: 53484.985125),
        .init(name: "04-13 22:50a", videoAnchorSeconds: 54290.435758, audioAnchorSeconds: 54290.472604166665),
        .init(name: "04-13 22:50b", videoAnchorSeconds: 54304.135685416, audioAnchorSeconds: 54304.16289583333),
        .init(name: "06-12 10:01", videoAnchorSeconds: 451976.332814625, audioAnchorSeconds: 451976.5485208333),
        .init(name: "06-12 10:05", videoAnchorSeconds: 452235.256197916, audioAnchorSeconds: 452235.29795833334),
        .init(name: "06-12 10:06a", videoAnchorSeconds: 452268.747656875, audioAnchorSeconds: 452268.77222916664),
        .init(name: "06-12 10:06b", videoAnchorSeconds: 452306.522421625, audioAnchorSeconds: 452306.5466041667),
        .init(name: "06-12 10:07a", videoAnchorSeconds: 452317.039023, audioAnchorSeconds: 452317.0616875),
        .init(name: "06-12 10:07b", videoAnchorSeconds: 452343.755523458, audioAnchorSeconds: 452343.7899375),
        .init(name: "06-12 10:37", videoAnchorSeconds: 454112.744404791, audioAnchorSeconds: 454112.77427083335),
        .init(name: "06-12 10:41", videoAnchorSeconds: 454378.842804166, audioAnchorSeconds: 454378.8758541667),
        .init(name: "06-12 10:54", videoAnchorSeconds: 455155.188105416, audioAnchorSeconds: 455155.2140208333),
    ]

    private static let audioSamplesPerBuffer: Int64 = 512
    private static let audioSampleRate: Int32 = 48_000

    /// The retimed audio timeline must satisfy
    /// pts[n+1] == pts[n] + duration[n] EXACTLY (as CMTimes, not
    /// seconds) for every session's anchor pair.
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

    // MARK: - Synthetic media factories

    /// Float32 interleaved stereo 48kHz — the source format
    /// ScreenCaptureKit delivers from the microphone.
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

    /// 512 frames of silence matching production's buffer shape
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
}
