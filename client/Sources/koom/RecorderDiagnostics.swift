@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import Darwin
import Foundation

/// Diagnostic data captured around a ScreenRecorder failure.
///
/// When `AVAssetWriter` fails mid-recording it usually surfaces an
/// undocumented `NSOSStatusErrorDomain` code and no context (the
/// -16122 idle-frame and -16341 fragment-flush bugs were both
/// diagnosed from these dumps). The collector instruments the audio
/// path cheaply during every recording and, on failure, writes one
/// structured forensic report to `AppLog.error` so the entire
/// context is visible in `~/Library/Logs/koom/koom.log`.
///
/// It keeps a ring buffer of the most recent audio buffers it saw
/// (size-capped, fixed-cost per insert), summary counters, PTS
/// continuity tracking, and a reference copy of the first audio
/// sample's format.
///
/// Everything is value-typed and the collector is used from the
/// recorder's serial sample queue, so there is no concurrent access
/// to worry about.
struct RecorderDiagnosticsCollector {
    private static let maxRecentAudioBuffers = 60

    // MARK: - Lifecycle

    private var recordingStartedAt: Date?
    private var initialAudioFormat: AudioStreamBasicDescription?
    private var initialAudioChannelLayoutSize: Int?
    private var microphoneUniqueID: String?
    private var initialDefaultInputDeviceID: AudioDeviceID?
    private var initialDefaultInputDeviceName: String?

    // MARK: - Counters

    private(set) var successfulAudioAppends: Int = 0
    private(set) var failedAudioAppends: Int = 0
    private(set) var audioBackpressureSamples: Int = 0
    private(set) var successfulVideoAppends: Int = 0
    private(set) var droppedVideoSamples: Int = 0
    private(set) var skippedNonCompleteVideoFrames: Int = 0
    private(set) var audioFormatDriftEventCount: Int = 0
    private var lastSuccessfulAudioAppendAt: Date?

    // MARK: - PTS continuity tracking
    //
    // Exact-CMTime invariants over the whole recording: each buffer's
    // PTS must equal the previous buffer's PTS plus its sample count.
    // Source continuity is checked on every buffer SCK delivers;
    // retimed continuity on appended buffers only (drops and segment
    // rollovers legitimately interrupt the appended timeline). Any
    // nonzero count in a failure dump means the timeline itself is
    // suspect.

    private var lastAudioSourcePTS: CMTime?
    private var lastAudioSourceSampleCount: CMItemCount = 0
    private(set) var audioSourcePTSDiscontinuities: Int = 0
    private var sourceDiscontinuityExamples: [String] = []
    private var lastAppendedRetimedPTS: CMTime?
    private var lastAppendedRetimedSampleCount: CMItemCount = 0
    private(set) var retimedPTSDiscontinuities: Int = 0
    private var maxRetimedGapSeconds: Double = 0
    private var retimedDiscontinuityExample: String?
    private(set) var segmentRollovers: Int = 0

    private static let maxDiscontinuityExamples = 5

    // MARK: - Ring buffers

    private var recentAudioBuffers: [AudioBufferSnapshot] = []

    // MARK: - Core Audio listener

    private var defaultInputListenerInstalled = false

    // MARK: - Public API

    mutating func start(
        recordingStartedAt: Date,
        microphoneUniqueID: String?
    ) {
        self.recordingStartedAt = recordingStartedAt
        self.microphoneUniqueID = microphoneUniqueID
        self.initialAudioFormat = nil
        self.initialAudioChannelLayoutSize = nil
        self.successfulAudioAppends = 0
        self.failedAudioAppends = 0
        self.audioBackpressureSamples = 0
        self.successfulVideoAppends = 0
        self.droppedVideoSamples = 0
        self.skippedNonCompleteVideoFrames = 0
        self.audioFormatDriftEventCount = 0
        self.lastSuccessfulAudioAppendAt = nil
        self.lastAudioSourcePTS = nil
        self.lastAudioSourceSampleCount = 0
        self.audioSourcePTSDiscontinuities = 0
        self.sourceDiscontinuityExamples.removeAll(keepingCapacity: true)
        self.lastAppendedRetimedPTS = nil
        self.lastAppendedRetimedSampleCount = 0
        self.retimedPTSDiscontinuities = 0
        self.maxRetimedGapSeconds = 0
        self.retimedDiscontinuityExample = nil
        self.segmentRollovers = 0
        self.recentAudioBuffers.removeAll(keepingCapacity: true)

        let (initialID, initialName) = RecorderDiagnosticsCollector.queryDefaultInputDevice()
        self.initialDefaultInputDeviceID = initialID
        self.initialDefaultInputDeviceName = initialName

        installDefaultInputDeviceListener()
    }

    mutating func stop() {
        removeDefaultInputDeviceListener()
    }

    /// Snapshot an audio sample buffer. Called on every audio
    /// buffer the recorder sees, regardless of whether it gets
    /// appended or dropped — we want the full picture on failure.
    mutating func recordAudioBuffer(
        _ sampleBuffer: CMSampleBuffer,
        sourcePTS: CMTime,
        retimedPTS: CMTime,
        outcome: AudioAppendOutcome
    ) {
        let now = Date()
        let snapshot = AudioBufferSnapshot(
            capturedAt: now,
            elapsedSinceStart: recordingStartedAt.map { now.timeIntervalSince($0) } ?? 0,
            sampleCount: CMSampleBufferGetNumSamples(sampleBuffer),
            totalSize: CMSampleBufferGetTotalSampleSize(sampleBuffer),
            dataBufferLength: RecorderDiagnosticsCollector.dataBufferLength(sampleBuffer),
            isValid: CMSampleBufferIsValid(sampleBuffer),
            dataReady: CMSampleBufferDataIsReady(sampleBuffer),
            duration: CMSampleBufferGetDuration(sampleBuffer),
            sourcePTS: sourcePTS,
            retimedPTS: retimedPTS,
            format: RecorderDiagnosticsCollector.asbd(of: sampleBuffer),
            channelLayoutSize: RecorderDiagnosticsCollector.channelLayoutSize(of: sampleBuffer),
            outcome: outcome
        )

        if initialAudioFormat == nil, let format = snapshot.format {
            initialAudioFormat = format
            initialAudioChannelLayoutSize = snapshot.channelLayoutSize
        } else if let expected = initialAudioFormat,
            let actual = snapshot.format,
            !RecorderDiagnosticsCollector.asbdEquals(expected, actual)
        {
            audioFormatDriftEventCount += 1
        }

        switch outcome {
        case .appended:
            successfulAudioAppends += 1
            lastSuccessfulAudioAppendAt = now
        case .backpressure:
            audioBackpressureSamples += 1
        case .appendFailed, .writerAlreadyFailed, .droppedNonMonotonic, .droppedInvalidRetime:
            failedAudioAppends += 1
        case .droppedPaused, .droppedWaitingForAnchor:
            // not an error state, just a transient drop
            break
        }

        // Source-PTS continuity: each buffer should start exactly where
        // the previous one ended (previous PTS + previous sample count).
        // A mismatch means the capture device's timeline jumped.
        if let sampleRate = snapshot.format?.mSampleRate, sampleRate > 0,
            CMTIME_IS_VALID(sourcePTS)
        {
            let rate = CMTimeScale(sampleRate)
            if let last = lastAudioSourcePTS {
                let expected = CMTimeAdd(
                    last,
                    CMTime(value: CMTimeValue(lastAudioSourceSampleCount), timescale: rate)
                )
                if CMTimeCompare(sourcePTS, expected) != 0 {
                    audioSourcePTSDiscontinuities += 1
                    if sourceDiscontinuityExamples.count < Self.maxDiscontinuityExamples {
                        let gap = CMTimeSubtract(sourcePTS, expected).seconds
                        sourceDiscontinuityExamples.append(
                            "t+\(String(format: "%.3f", snapshot.elapsedSinceStart))s expected=\(describeRawCMTime(expected)) got=\(describeRawCMTime(sourcePTS)) gap=\(String(format: "%+.9f", gap))s"
                        )
                    }
                }
            }
            lastAudioSourcePTS = sourcePTS
            lastAudioSourceSampleCount = snapshot.sampleCount

            // Retimed continuity over the appended timeline — what the
            // writer actually sees. Expected to be exactly contiguous
            // since the timescale-converted retiming fix; count, track
            // the worst gap, and keep one example.
            if outcome == .appended, CMTIME_IS_VALID(retimedPTS) {
                if let last = lastAppendedRetimedPTS {
                    let expected = CMTimeAdd(
                        last,
                        CMTime(
                            value: CMTimeValue(lastAppendedRetimedSampleCount),
                            timescale: rate
                        )
                    )
                    if CMTimeCompare(retimedPTS, expected) != 0 {
                        retimedPTSDiscontinuities += 1
                        let gap = CMTimeSubtract(retimedPTS, expected).seconds
                        if abs(gap) > abs(maxRetimedGapSeconds) {
                            maxRetimedGapSeconds = gap
                        }
                        if retimedDiscontinuityExample == nil {
                            retimedDiscontinuityExample =
                                "t+\(String(format: "%.3f", snapshot.elapsedSinceStart))s expected=\(describeRawCMTime(expected)) got=\(describeRawCMTime(retimedPTS)) gap=\(String(format: "%+.9f", gap))s"
                        }
                    }
                }
                lastAppendedRetimedPTS = retimedPTS
                lastAppendedRetimedSampleCount = snapshot.sampleCount
            }
        }

        appendRingBuffer(&recentAudioBuffers, snapshot, limit: Self.maxRecentAudioBuffers)
    }

    /// Each segment's timeline restarts at zero, so the appended
    /// retimed PTS legitimately jumps backward at a rollover. Reset
    /// the retimed continuity tracking instead of counting the seam
    /// as a discontinuity. (Source continuity spans the whole
    /// recording and is unaffected.)
    mutating func noteSegmentRollover() {
        segmentRollovers += 1
        lastAppendedRetimedPTS = nil
        lastAppendedRetimedSampleCount = 0
    }

    mutating func recordVideoAppend(success: Bool) {
        if success {
            successfulVideoAppends += 1
        } else {
            droppedVideoSamples += 1
        }
    }

    /// Idle/blank SCK frames (no pixel data) that the recorder
    /// refused to append. A nonzero count is normal on a static
    /// screen; the counter exists to correlate frame gaps with any
    /// future writer failure.
    mutating func recordSkippedVideoFrame() {
        skippedNonCompleteVideoFrames += 1
    }

    /// Emit a structured forensic dump to AppLog.error at the
    /// moment we detect a writer failure. This is the whole point
    /// of the collector — capture everything we know about the
    /// state of the world at the instant the writer crashed.
    func emitFailureReport(
        reason: String,
        failingTrack: RecorderTrack?,
        failingBuffer: CMSampleBuffer?,
        failingBufferSourcePTS: CMTime?,
        failingBufferRetimedPTS: CMTime?,
        writer: AVAssetWriter?,
        audioInput: AVAssetWriterInput?,
        videoInput: AVAssetWriterInput?
    ) {
        var lines: [String] = []
        let banner = String(repeating: "━", count: 72)

        lines.append(banner)
        lines.append("[koom recorder] FAILURE DIAGNOSTICS — \(reason)")
        lines.append(banner)

        // ── Context ────────────────────────────────────────────
        lines.append("")
        lines.append("Context:")
        if let start = recordingStartedAt {
            let elapsed = Date().timeIntervalSince(start)
            lines.append("  Elapsed since recording start: \(String(format: "%.3f", elapsed))s")
        }
        if let failingTrack {
            lines.append("  Failing track: \(failingTrack.rawValue)")
        }
        lines.append("  Audio appends: ok=\(successfulAudioAppends) failed=\(failedAudioAppends) backpressure=\(audioBackpressureSamples)")
        lines.append(
            "  Video appends: ok=\(successfulVideoAppends) dropped=\(droppedVideoSamples) skippedNonComplete=\(skippedNonCompleteVideoFrames)")
        lines.append("  Audio format drift events: \(audioFormatDriftEventCount)")
        lines.append("  Segment rollovers: \(segmentRollovers)")
        lines.append("  Audio source PTS discontinuities: \(audioSourcePTSDiscontinuities)")
        for example in sourceDiscontinuityExamples {
            lines.append("    \(example)")
        }
        lines.append(
            "  Retimed PTS discontinuities (appended timeline): \(retimedPTSDiscontinuities) maxGap=\(String(format: "%+.9f", maxRetimedGapSeconds))s"
        )
        if let retimedDiscontinuityExample {
            lines.append("    first: \(retimedDiscontinuityExample)")
        }
        if let last = lastSuccessfulAudioAppendAt {
            let gap = Date().timeIntervalSince(last)
            lines.append("  Time since last successful audio append: \(String(format: "%.3f", gap))s")
        } else {
            lines.append("  Time since last successful audio append: (none yet)")
        }

        // ── Writer state ───────────────────────────────────────
        lines.append("")
        lines.append("Writer state:")
        if let writer {
            lines.append("  status: \(describe(writer.status)) (\(writer.status.rawValue))")
            lines.append("  outputURL: \(writer.outputURL.path)")
            if let error = writer.error {
                lines.append("  error:")
                for line in describeErrorChain(error) {
                    lines.append("    \(line)")
                }
            } else {
                lines.append("  error: (none)")
            }
        } else {
            lines.append("  (writer is nil)")
        }

        // ── Audio input state ──────────────────────────────────
        lines.append("")
        lines.append("Audio input state:")
        if let audioInput {
            lines.append("  mediaType: \(audioInput.mediaType.rawValue)")
            lines.append("  isReadyForMoreMediaData: \(audioInput.isReadyForMoreMediaData)")
            lines.append("  expectsMediaDataInRealTime: \(audioInput.expectsMediaDataInRealTime)")
            if let hint = audioInput.sourceFormatHint {
                lines.append("  sourceFormatHint: \(describeFormatDescription(hint))")
            } else {
                lines.append("  sourceFormatHint: (none)")
            }
            if let settings = audioInput.outputSettings {
                lines.append("  outputSettings: \(formatSettings(settings))")
            } else {
                lines.append("  outputSettings: (none)")
            }
        } else {
            lines.append("  (audio input is nil)")
        }

        // ── Video input state (for context) ────────────────────
        lines.append("")
        lines.append("Video input state:")
        if let videoInput {
            lines.append("  isReadyForMoreMediaData: \(videoInput.isReadyForMoreMediaData)")
            lines.append("  expectsMediaDataInRealTime: \(videoInput.expectsMediaDataInRealTime)")
        } else {
            lines.append("  (video input is nil)")
        }

        // ── Initial vs failing format ──────────────────────────
        lines.append("")
        lines.append("Initial audio sample format (first SCK buffer we saw):")
        if let initialAudioFormat {
            for line in describeASBD(initialAudioFormat) {
                lines.append("  \(line)")
            }
            if let size = initialAudioChannelLayoutSize {
                lines.append("  channelLayoutSize: \(size) bytes")
            }
        } else {
            lines.append("  (no audio buffers were ever captured)")
        }

        if let failingBuffer {
            lines.append("")
            lines.append("Failing sample buffer:")
            lines.append("  sampleCount: \(CMSampleBufferGetNumSamples(failingBuffer))")
            lines.append("  totalSize: \(CMSampleBufferGetTotalSampleSize(failingBuffer)) bytes")
            lines.append("  dataBufferLength: \(Self.dataBufferLength(failingBuffer) ?? -1) bytes")
            lines.append("  isValid: \(CMSampleBufferIsValid(failingBuffer))")
            lines.append("  dataReady: \(CMSampleBufferDataIsReady(failingBuffer))")
            let dur = CMSampleBufferGetDuration(failingBuffer)
            if CMTIME_IS_VALID(dur) {
                lines.append("  duration: \(describeRawCMTime(dur))")
            }
            if let pts = failingBufferSourcePTS, CMTIME_IS_VALID(pts) {
                lines.append("  sourcePTS: \(describeRawCMTime(pts))")
            }
            if let pts = failingBufferRetimedPTS, CMTIME_IS_VALID(pts) {
                lines.append("  retimedPTS: \(describeRawCMTime(pts))")
            }
            if let asbd = Self.asbd(of: failingBuffer) {
                for line in describeASBD(asbd) {
                    lines.append("  \(line)")
                }
                if let initial = initialAudioFormat, !Self.asbdEquals(initial, asbd) {
                    lines.append("  FORMAT DRIFT: this buffer's ASBD differs from the initial one")
                }
            } else {
                lines.append("  (no CMAudioFormatDescription on the failing buffer)")
            }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(
                failingBuffer,
                createIfNecessary: false
            ) as? [[CFString: Any]] {
                lines.append("  sampleAttachments: \(attachments.count) entries")
                for (i, entry) in attachments.prefix(4).enumerated() {
                    lines.append("    [\(i)] keys=\(entry.keys.map { $0 as String }.sorted())")
                }
            } else {
                lines.append("  sampleAttachments: (none)")
            }
        }

        // ── Recent audio buffer history ────────────────────────
        lines.append("")
        lines.append("Recent audio buffers (newest last, max \(Self.maxRecentAudioBuffers)):")
        if recentAudioBuffers.isEmpty {
            lines.append("  (empty)")
        } else {
            for (i, snap) in recentAudioBuffers.enumerated() {
                lines.append("  [\(i)] \(describe(snap))")
            }
        }

        // ── Microphone device state ────────────────────────────
        lines.append("")
        lines.append("Capture device state:")
        if let uniqueID = microphoneUniqueID {
            if let device = AVCaptureDevice(uniqueID: uniqueID) {
                lines.append("  AVCaptureDevice: \(device.localizedName) [\(uniqueID)]")
                lines.append("  isConnected: \(device.isConnected)")
                lines.append("  isInUseByAnotherApplication: \(device.isInUseByAnotherApplication)")
                lines.append("  isSuspended: \(device.isSuspended)")
                if let asbd = Self.asbd(of: device.activeFormat.formatDescription) {
                    lines.append("  activeFormat ASBD:")
                    for line in describeASBD(asbd) {
                        lines.append("    \(line)")
                    }
                }
            } else {
                lines.append("  AVCaptureDevice lookup failed for uniqueID=\(uniqueID)")
            }
        } else {
            lines.append("  (no microphone configured)")
        }

        // ── Core Audio default-input state ─────────────────────
        lines.append("")
        lines.append("Core Audio default input device:")
        if let initialID = initialDefaultInputDeviceID {
            let initialName = initialDefaultInputDeviceName ?? "(unknown)"
            lines.append("  initial: id=\(initialID) name=\"\(initialName)\"")
        } else {
            lines.append("  initial: (not captured)")
        }
        let (nowID, nowName) = Self.queryDefaultInputDevice()
        if let nowID {
            let name = nowName ?? "(unknown)"
            lines.append("  now: id=\(nowID) name=\"\(name)\"")
            if let initialID = initialDefaultInputDeviceID, initialID != nowID {
                lines.append("  DEFAULT INPUT DEVICE CHANGED during recording")
            }
        } else {
            lines.append("  now: (query failed)")
        }

        // ── Process / system ───────────────────────────────────
        lines.append("")
        lines.append("Process state:")
        let info = ProcessInfo.processInfo
        lines.append("  systemUptime: \(String(format: "%.1f", info.systemUptime))s")
        lines.append("  activeProcessorCount: \(info.activeProcessorCount)")
        lines.append("  physicalMemory: \(info.physicalMemory) bytes")
        lines.append("  thermalState: \(describe(info.thermalState))")
        if let footprint = Self.residentMemoryBytes() {
            lines.append("  residentMemory: \(footprint) bytes")
        }

        lines.append("")
        lines.append(banner)

        for line in lines {
            AppLog.error(line)
        }
    }

    // MARK: - Audio device change listener

    private mutating func installDefaultInputDeviceListener() {
        guard !defaultInputListenerInstalled else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .userInitiated),
            RecorderDiagnosticsCollector.defaultInputDeviceChangedHandler
        )

        if status == noErr {
            defaultInputListenerInstalled = true
        } else {
            AppLog.error("RecorderDiagnostics: failed to install default-input listener (OSStatus \(status))")
        }
    }

    private mutating func removeDefaultInputDeviceListener() {
        guard defaultInputListenerInstalled else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .userInitiated),
            RecorderDiagnosticsCollector.defaultInputDeviceChangedHandler
        )
        defaultInputListenerInstalled = false
    }

    /// Static block shared by install/remove. The Core Audio block
    /// runs on a CA queue, not our sample queue, so it can't mutate
    /// the collector; it logs directly to AppLog so the event is
    /// persisted, timestamped, and shows up near any failure
    /// diagnostics in chronological order.
    nonisolated(unsafe) private static let defaultInputDeviceChangedHandler: AudioObjectPropertyListenerBlock = { _, _ in
        let (id, name) = queryDefaultInputDevice()
        let nameString = name ?? "(unknown)"
        let idString = id.map { "\($0)" } ?? "(nil)"
        AppLog.error(
            "CoreAudio: default input device changed. new id=\(idString) name=\"\(nameString)\""
        )
    }

    // MARK: - Helpers

    private static func queryDefaultInputDevice() -> (
        AudioDeviceID?,
        String?
    ) {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else {
            return (nil, nil)
        }
        let name = deviceName(deviceID)
        return (deviceID, name)
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &name
        )
        guard status == noErr, let cfString = name?.takeRetainedValue() else {
            return nil
        }
        return cfString as String
    }

    private static func asbd(
        of sampleBuffer: CMSampleBuffer
    ) -> AudioStreamBasicDescription? {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        else {
            return nil
        }
        return asbd(of: formatDescription)
    }

    private static func asbd(
        of formatDescription: CMFormatDescription
    ) -> AudioStreamBasicDescription? {
        guard CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Audio
        else {
            return nil
        }
        return CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?
            .pointee
    }

    private static func asbdEquals(
        _ a: AudioStreamBasicDescription,
        _ b: AudioStreamBasicDescription
    ) -> Bool {
        return
            a.mSampleRate == b.mSampleRate
            && a.mFormatID == b.mFormatID
            && a.mFormatFlags == b.mFormatFlags
            && a.mBytesPerPacket == b.mBytesPerPacket
            && a.mFramesPerPacket == b.mFramesPerPacket
            && a.mBytesPerFrame == b.mBytesPerFrame
            && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel
    }

    private static func channelLayoutSize(
        of sampleBuffer: CMSampleBuffer
    ) -> Int? {
        guard
            let format = CMSampleBufferGetFormatDescription(sampleBuffer),
            CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio
        else {
            return nil
        }
        var size: Int = 0
        guard
            CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &size) != nil
        else {
            return nil
        }
        return size
    }

    private static func dataBufferLength(
        _ sampleBuffer: CMSampleBuffer
    ) -> Int? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }
        return CMBlockBufferGetDataLength(blockBuffer)
    }

    private static func residentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { infoPtr -> kern_return_t in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return info.resident_size
    }

    private func appendRingBuffer<Element>(
        _ buffer: inout [Element],
        _ element: Element,
        limit: Int
    ) {
        buffer.append(element)
        if buffer.count > limit {
            buffer.removeFirst(buffer.count - limit)
        }
    }

    // MARK: - Descriptions

    private func describeASBD(_ asbd: AudioStreamBasicDescription) -> [String] {
        [
            "formatID: \(fourCCDescription(asbd.mFormatID))",
            "sampleRate: \(asbd.mSampleRate)",
            "formatFlags: \(formatFlagsDescription(asbd: asbd))",
            "bytesPerPacket: \(asbd.mBytesPerPacket)",
            "framesPerPacket: \(asbd.mFramesPerPacket)",
            "bytesPerFrame: \(asbd.mBytesPerFrame)",
            "channelsPerFrame: \(asbd.mChannelsPerFrame)",
            "bitsPerChannel: \(asbd.mBitsPerChannel)",
        ]
    }

    private func describe(_ snap: AudioBufferSnapshot) -> String {
        let asbdDescription: String
        if let format = snap.format {
            asbdDescription =
                "\(fourCCDescription(format.mFormatID))/\(format.mSampleRate)/\(format.mChannelsPerFrame)ch/\(format.mBitsPerChannel)b/flags=0x\(String(format.mFormatFlags, radix: 16))"
        } else {
            asbdDescription = "(no-fmt)"
        }
        let elapsed = String(format: "%.3fs", snap.elapsedSinceStart)
        return
            "t+\(elapsed) \(snap.outcome.rawValue) samples=\(snap.sampleCount) bytes=\(snap.totalSize) dbl=\(snap.dataBufferLength ?? -1) valid=\(snap.isValid ? 1 : 0) dataReady=\(snap.dataReady ? 1 : 0) dur=\(describeRawCMTime(snap.duration)) srcPTS=\(describeRawCMTime(snap.sourcePTS)) rtPTS=\(describeRawCMTime(snap.retimedPTS)) fmt=\(asbdDescription)"
    }

    /// Renders a CMTime as seconds plus the exact value/timescale —
    /// "4.2179(4217915417/1000000000+R)". Sub-microsecond timing
    /// detail (e.g. 1ns retiming gaps) is invisible at any fixed
    /// decimal rendering, so the raw rational is the part that
    /// matters. "+R" marks kCMTimeFlags_HasBeenRounded.
    private func describeRawCMTime(_ time: CMTime) -> String {
        guard CMTIME_IS_VALID(time) else { return "invalid" }
        let rounded = time.flags.contains(.hasBeenRounded) ? "+R" : ""
        return
            "\(String(format: "%.4f", time.seconds))(\(time.value)/\(time.timescale)\(rounded))"
    }

    private func describe(_ status: AVAssetWriter.Status) -> String {
        switch status {
        case .unknown: return "unknown"
        case .writing: return "writing"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    private func describeErrorChain(_ error: Error) -> [String] {
        var lines: [String] = []
        var current: Error? = error
        var depth = 0
        while let next = current {
            let nsError = next as NSError
            let prefix = depth == 0 ? "" : String(repeating: "  ", count: depth)
            lines.append("\(prefix)domain=\(nsError.domain) code=\(nsError.code)")
            lines.append("\(prefix)description=\(nsError.localizedDescription)")
            if !nsError.userInfo.isEmpty {
                for (key, value) in nsError.userInfo
                where key != NSUnderlyingErrorKey {
                    lines.append("\(prefix)userInfo[\(key)]=\(value)")
                }
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? Error
            depth += 1
            if depth > 6 {
                lines.append("... (truncated deeper error chain)")
                break
            }
        }
        return lines
    }

    private func describeFormatDescription(
        _ formatDescription: CMFormatDescription
    ) -> String {
        let mediaType = CMFormatDescriptionGetMediaType(formatDescription)
        let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDescription)
        return
            "type=\(fourCCDescription(mediaType)) subtype=\(fourCCDescription(mediaSubType))"
    }

    private func formatSettings(_ settings: [String: Any]) -> String {
        settings
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
    }

    private func fourCCDescription(_ value: FourCharCode) -> String {
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

    private func formatFlagsDescription(asbd: AudioStreamBasicDescription) -> String {
        let flags = asbd.mFormatFlags
        var parts: [String] = []
        parts.append(String(format: "0x%08X", flags))
        if asbd.mFormatID == kAudioFormatLinearPCM {
            if flags & kAudioFormatFlagIsFloat != 0 { parts.append("IsFloat") }
            if flags & kAudioFormatFlagIsBigEndian != 0 { parts.append("IsBigEndian") }
            if flags & kAudioFormatFlagIsSignedInteger != 0 {
                parts.append("IsSignedInteger")
            }
            if flags & kAudioFormatFlagIsPacked != 0 { parts.append("IsPacked") }
            if flags & kAudioFormatFlagIsAlignedHigh != 0 {
                parts.append("IsAlignedHigh")
            }
            if flags & kAudioFormatFlagIsNonInterleaved != 0 {
                parts.append("IsNonInterleaved")
            }
            if flags & kAudioFormatFlagIsNonMixable != 0 {
                parts.append("IsNonMixable")
            }
        }
        return parts.joined(separator: " ")
    }
}

/// Reason we captured a given audio sample buffer. The tag shows
/// up in the ring buffer dump so we can see the pattern leading up
/// to failure (e.g. 20 successful appends, 1 backpressure, then
/// the failing append).
enum AudioAppendOutcome: String {
    case appended
    case appendFailed = "append-failed"
    case writerAlreadyFailed = "writer-already-failed"
    case backpressure
    case droppedNonMonotonic = "dropped-nonmonotonic"
    case droppedPaused = "dropped-paused"
    case droppedWaitingForAnchor = "dropped-waiting-for-anchor"
    case droppedInvalidRetime = "dropped-invalid-retime"
}

/// Value-type snapshot of a CMSampleBuffer at the moment we saw
/// it. Kept to a fixed size so we can ring-buffer ~60 of them for
/// cheap.
struct AudioBufferSnapshot {
    let capturedAt: Date
    let elapsedSinceStart: TimeInterval
    let sampleCount: CMItemCount
    let totalSize: Int
    let dataBufferLength: Int?
    let isValid: Bool
    let dataReady: Bool
    let duration: CMTime
    let sourcePTS: CMTime
    let retimedPTS: CMTime
    let format: AudioStreamBasicDescription?
    let channelLayoutSize: Int?
    let outcome: AudioAppendOutcome
}
