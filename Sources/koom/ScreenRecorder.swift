@preconcurrency import AVFoundation
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
    struct Configuration {
        let displayID: CGDirectDisplayID
        let microphoneID: String?
        let outputURL: URL
    }

    private let configuration: Configuration
    private let sampleQueue = DispatchQueue(label: "koom.recording.samples")

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var microphoneCapture: MicrophoneCapture?
    private var sessionStartPTS: CMTime?
    private var accumulatedPauseOffset: CMTime = .zero
    private var pauseStartPTS: CMTime?
    private var resumeNeedsOffset = false
    private var lastSourcePTS: CMTime = .invalid
    private var isPaused = false

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func start() async throws {
        AppLog.info("Recorder starting. Display ID: \(configuration.displayID), microphone: \(configuration.microphoneID ?? "none"), output: \(configuration.outputURL.path)")
        if FileManager.default.fileExists(atPath: configuration.outputURL.path) {
            try FileManager.default.removeItem(at: configuration.outputURL)
        }

        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = shareableContent.displays.first(where: { $0.displayID == configuration.displayID }) else {
            throw RecorderError.displayNotFound
        }

        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = display.width
        streamConfiguration.height = display.height
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        streamConfiguration.queueDepth = 6
        streamConfiguration.showsCursor = true
        streamConfiguration.capturesAudio = false

        let contentFilter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: contentFilter, configuration: streamConfiguration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

        let writer = try AVAssetWriter(outputURL: configuration.outputURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(width: display.width, height: display.height))
        videoInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput) else {
            throw RecorderError.writerFailed("koom could not add a video track to the recording.")
        }

        writer.add(videoInput)

        self.writer = writer
        self.videoInput = videoInput

        if let microphoneID = configuration.microphoneID {
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings())
            audioInput.expectsMediaDataInRealTime = true

            guard writer.canAdd(audioInput) else {
                throw RecorderError.writerFailed("koom could not add an audio track to the recording.")
            }

            writer.add(audioInput)
            self.audioInput = audioInput
            microphoneCapture = try MicrophoneCapture(deviceID: microphoneID, outputQueue: sampleQueue) { [weak self] sampleBuffer in
                self?.append(sampleBuffer: sampleBuffer, mediaType: .audio)
            }
        }

        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "koom could not start writing the movie file.")
        }

        self.stream = stream

        do {
            try await stream.startCapture()
            try await microphoneCapture?.start()
            AppLog.info("Recorder capture started.")
        } catch {
            try? await stream.stopCapture()
            AppLog.error("Recorder failed to start: \(error.localizedDescription)")
            throw error
        }
    }

    func pause() {
        sampleQueue.async {
            guard !self.isPaused else { return }
            self.isPaused = true
            self.pauseStartPTS = CMTIME_IS_VALID(self.lastSourcePTS) ? self.lastSourcePTS : nil
            AppLog.info("Recorder paused.")
        }
    }

    func resume() {
        sampleQueue.async {
            guard self.isPaused else { return }
            self.isPaused = false
            self.resumeNeedsOffset = true
            AppLog.info("Recorder resumed.")
        }
    }

    func stop(discardOutput: Bool) async throws -> URL {
        guard let writer else {
            throw RecorderError.recorderNotRunning
        }

        AppLog.info("Recorder stopping. Discard output: \(discardOutput)")
        try? await stream?.stopCapture()
        microphoneCapture?.stop()

        return try await withCheckedThrowingContinuation { continuation in
            sampleQueue.async {
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()

                writer.finishWriting {
                    defer {
                        self.stream = nil
                        self.writer = nil
                        self.videoInput = nil
                        self.audioInput = nil
                        self.microphoneCapture = nil
                        self.sessionStartPTS = nil
                        self.accumulatedPauseOffset = .zero
                        self.pauseStartPTS = nil
                        self.resumeNeedsOffset = false
                        self.lastSourcePTS = .invalid
                        self.isPaused = false
                    }

                    if discardOutput {
                        try? FileManager.default.removeItem(at: self.configuration.outputURL)
                        AppLog.info("Discarded recording at \(self.configuration.outputURL.path)")
                    }

                    if writer.status == .completed || discardOutput {
                        AppLog.info("Recorder finished writing \(self.configuration.outputURL.path)")
                        continuation.resume(returning: self.configuration.outputURL)
                        return
                    }

                    let reason = writer.error?.localizedDescription ?? "koom could not finalize the recording."
                    AppLog.error("Recorder failed to finalize: \(reason)")
                    continuation.resume(throwing: RecorderError.writerFailed(reason))
                }
            }
        }
    }

    private func append(sampleBuffer: CMSampleBuffer, mediaType: AVMediaType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }

        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if CMTIME_IS_VALID(sourcePTS) {
            lastSourcePTS = sourcePTS
        }

        if isPaused {
            if pauseStartPTS == nil, CMTIME_IS_VALID(sourcePTS) {
                pauseStartPTS = sourcePTS
            }
            return
        }

        if resumeNeedsOffset, let pauseStartPTS, CMTIME_IS_VALID(sourcePTS) {
            let pauseDelta = CMTimeSubtract(sourcePTS, pauseStartPTS)
            if pauseDelta > .zero {
                accumulatedPauseOffset = CMTimeAdd(accumulatedPauseOffset, pauseDelta)
            }
            self.pauseStartPTS = nil
            resumeNeedsOffset = false
        }

        if sessionStartPTS == nil, CMTIME_IS_VALID(sourcePTS) {
            sessionStartPTS = sourcePTS
            writer?.startSession(atSourceTime: .zero)
        }

        guard let sessionStartPTS else { return }
        let offset = CMTimeAdd(sessionStartPTS, accumulatedPauseOffset)

        guard let retimedBuffer = sampleBuffer.retimed(bySubtracting: offset) else { return }

        switch mediaType {
        case .video:
            guard let videoInput, videoInput.isReadyForMoreMediaData else { return }
            _ = videoInput.append(retimedBuffer)
        case .audio:
            guard let audioInput, audioInput.isReadyForMoreMediaData else { return }
            _ = audioInput.append(retimedBuffer)
        default:
            return
        }
    }

    private static func videoSettings(width: Int, height: Int) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(width * height * 4, 8_000_000),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
    }

    private static func audioSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]
    }
}

extension ScreenRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        append(sampleBuffer: sampleBuffer, mediaType: .video)
    }
}

private final class MicrophoneCapture: NSObject, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "koom.microphone.session")
    private let outputQueue: DispatchQueue
    private let deviceID: String
    private let handler: (CMSampleBuffer) -> Void

    private var audioInput: AVCaptureDeviceInput?
    private let audioOutput = AVCaptureAudioDataOutput()

    init(deviceID: String, outputQueue: DispatchQueue, handler: @escaping (CMSampleBuffer) -> Void) throws {
        self.deviceID = deviceID
        self.outputQueue = outputQueue
        self.handler = handler

        super.init()

        try configureSession()
        AppLog.info("Configured microphone capture for device \(deviceID)")
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                self.session.startRunning()
                AppLog.info("Microphone capture started.")
                continuation.resume()
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
                AppLog.info("Microphone capture stopped.")
            }
        }
    }

    private func configureSession() throws {
        guard let device = CaptureDeviceCatalog.microphones().first(where: { $0.uniqueID == deviceID }) else {
            throw RecorderError.microphoneNotFound
        }

        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()

        if session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }

        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
            audioOutput.setSampleBufferDelegate(self, queue: outputQueue)
        }

        session.commitConfiguration()
    }
}

extension MicrophoneCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handler(sampleBuffer)
    }
}

private extension CMSampleBuffer {
    func retimed(bySubtracting offset: CMTime) -> CMSampleBuffer? {
        var timingEntryCount = 0
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: 0, arrayToFill: nil, entriesNeededOut: &timingEntryCount)

        guard timingEntryCount > 0 else {
            return self
        }

        var timings = Array(
            repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid),
            count: timingEntryCount
        )

        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: timingEntryCount, arrayToFill: &timings, entriesNeededOut: &timingEntryCount)

        for index in timings.indices {
            if CMTIME_IS_VALID(timings[index].presentationTimeStamp) {
                timings[index].presentationTimeStamp = CMTimeSubtract(timings[index].presentationTimeStamp, offset)
            }

            if CMTIME_IS_VALID(timings[index].decodeTimeStamp) {
                timings[index].decodeTimeStamp = CMTimeSubtract(timings[index].decodeTimeStamp, offset)
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
