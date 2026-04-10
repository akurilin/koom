@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
@preconcurrency import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case displayNotFound
    case writerFailed(String)
    case recorderNotRunning
    case microphoneNotFound
    case couldNotCreateRetimedBuffer

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
        case .couldNotCreateRetimedBuffer:
            return "koom could not retime a sample buffer while recording."
        }
    }
}

final class ScreenRecorder: NSObject, @unchecked Sendable {
    typealias RuntimeIssueHandler = @Sendable (String) -> Void

    struct Configuration {
        let displayID: CGDirectDisplayID
        let microphoneID: String?
        let outputURL: URL
        let movieFragmentInterval: CMTime?
        let expectedFrameRate: Int
    }

    private struct MicrophoneConfiguration {
        let writerSettings: [String: Any]
    }

    private let configuration: Configuration
    private let onRuntimeIssue: RuntimeIssueHandler?
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
    private var hasLoggedWriterFailure = false
    private var hasReportedRuntimeIssue = false

    init(
        configuration: Configuration,
        onRuntimeIssue: RuntimeIssueHandler? = nil
    ) {
        self.configuration = configuration
        self.onRuntimeIssue = onRuntimeIssue
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

        let writer = try AVAssetWriter(
            outputURL: configuration.outputURL,
            fileType: .mp4
        )
        if let movieFragmentInterval = configuration.movieFragmentInterval {
            writer.movieFragmentInterval = movieFragmentInterval
        }

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.videoSettings(
                width: display.width,
                height: display.height,
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

        self.writer = writer
        self.videoInput = videoInput

        if let microphoneConfiguration {
            let audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: microphoneConfiguration.writerSettings
            )
            audioInput.expectsMediaDataInRealTime = true

            guard writer.canAdd(audioInput) else {
                throw RecorderError.writerFailed(
                    "koom could not add an audio track to the recording."
                )
            }

            writer.add(audioInput)
            self.audioInput = audioInput
            AppLog.info(
                "Using microphone writer settings: \(Self.formatSettingsDescription(microphoneConfiguration.writerSettings))"
            )
        }

        guard writer.startWriting() else {
            throw RecorderError.writerFailed(
                writer.error?.localizedDescription
                    ?? "koom could not start writing the movie file."
            )
        }

        self.stream = stream

        do {
            try await stream.startCapture()
            AppLog.info("Recorder capture started.")
        } catch {
            try? await stream.stopCapture()
            AppLog.error("Recorder failed to start: \(error.localizedDescription)")
            throw error
        }
    }

    func pause() {
        sampleQueue.async {
            self.timeline.pause()
            AppLog.info("Recorder paused.")
        }
    }

    func resume() {
        sampleQueue.async {
            self.timeline.resume()
            AppLog.info("Recorder resumed.")
        }
    }

    func stop(discardOutput: Bool) async throws -> URL {
        guard let writer else {
            throw RecorderError.recorderNotRunning
        }

        isStopping = true
        AppLog.info("Recorder stopping. Discard output: \(discardOutput)")
        try? await stream?.stopCapture()
        await drainSampleQueue()

        await withCheckedContinuation { continuation in
            sampleQueue.async {
                self.isFinishing = true
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                continuation.resume()
            }
        }

        await writer.finishWriting()

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
            hasLoggedWriterFailure = false
            hasReportedRuntimeIssue = false
        }

        if discardOutput {
            try? FileManager.default.removeItem(at: configuration.outputURL)
            AppLog.info("Discarded recording at \(configuration.outputURL.path)")
        }

        if writer.status == .completed || discardOutput {
            AppLog.info("Recorder finished writing \(configuration.outputURL.path)")
            return configuration.outputURL
        }

        let reason = Self.writerFailureDescription(writer)
        AppLog.error("Recorder failed to finalize: \(reason)")
        throw RecorderError.writerFailed(reason)
    }

    private func append(sampleBuffer: CMSampleBuffer, mediaType: AVMediaType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        guard !isFinishing else { return }

        if writer?.status == .failed {
            reportRuntimeIssue(
                "The movie writer failed mid-recording. \(Self.writerFailureDescription(writer))"
            )
            return
        }

        switch mediaType {
        case .video:
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
                track: .video
            )
        case .audio:
            guard
                let retimedBuffer = prepareRetimedBuffer(
                    sampleBuffer,
                    track: .audio
                )
            else {
                return
            }
            appendPreparedBuffer(
                retimedBuffer,
                to: audioInput,
                track: .audio
            )
        default:
            return
        }
    }

    private func appendPreparedBuffer(
        _ sampleBuffer: CMSampleBuffer,
        to input: AVAssetWriterInput?,
        track: RecorderTrack
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

        if !input.append(sampleBuffer) {
            logWriterFailureIfNeeded(
                whileAppending: track,
                sampleBuffer: sampleBuffer
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
            )
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

        return Data(
            bytes: &channelLayout,
            count: MemoryLayout<AudioChannelLayout>.size
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
            append(sampleBuffer: sampleBuffer, mediaType: .video)
        case .microphone:
            append(sampleBuffer: sampleBuffer, mediaType: .audio)
        default:
            return
        }
    }
}

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        sampleQueue.async {
            guard !self.isStopping else { return }

            let nsError = error as NSError
            self.reportRuntimeIssue(
                "ScreenCaptureKit stopped the recording unexpectedly. domain=\(nsError.domain) code=\(nsError.code) \(error.localizedDescription)"
            )
        }
    }
}

private extension CMSampleBuffer {
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
