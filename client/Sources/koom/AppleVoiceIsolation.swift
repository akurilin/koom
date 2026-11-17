import AVFoundation

/// Offline voice isolation through Apple's AUSoundIsolation Audio Unit (the
/// high-quality model behind FaceTime's Voice Isolation). Built into macOS,
/// so it needs no download; it is also the fallback when the selected model
/// isn't installed. Ported from scripts/audio-lab/isolate.swift, where it
/// was rated.
///
/// The unit reports zero latency but delays its output by a model-specific
/// amount (4440 frames for the high-quality model on macOS 27), so each run
/// measures the delay with an impulse and trims it to stay in sync.
enum AppleVoiceIsolation {
    struct IsolationError: LocalizedError {
        let errorDescription: String?

        init(_ message: String) {
            errorDescription = message
        }
    }

    private static let renderChunk: AVAudioFrameCount = 4096

    /// Writes 32-bit float WAV with the input's format and exact frame
    /// count, time-aligned with the input. Blocks; call off the main actor.
    static func process(input: URL, output: URL) throws {
        let inputFile = try AVAudioFile(forReading: input)
        let format = inputFile.processingFormat
        let inputFrames = inputFile.length
        let latency = try measureLatency(format: format)

        let (engine, player) = try makeEngine(format: format, mix: 100)
        defer { engine.stop() }
        player.scheduleFile(inputFile, at: nil)
        player.play()

        let outputFile = try AVAudioFile(
            forWriting: output,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        // Render `latency` frames past the end of the input, drop the first
        // `latency` frames, and keep exactly the input's frame count.
        var position: AVAudioFramePosition = 0
        try render(engine, frameCount: inputFrames + latency) { buffer in
            let chunkStart = position
            position += AVAudioFramePosition(buffer.frameLength)
            let skip = max(0, latency - chunkStart)
            let take = AVAudioFramePosition(buffer.frameLength) - skip
            guard take > 0 else { return }
            if skip == 0 {
                try outputFile.write(from: buffer)
                return
            }
            guard
                let slice = AVAudioPCMBuffer(
                    pcmFormat: buffer.format,
                    frameCapacity: AVAudioFrameCount(take)
                ),
                let source = buffer.floatChannelData,
                let destination = slice.floatChannelData
            else {
                throw IsolationError("Could not allocate an audio buffer.")
            }
            for channel in 0..<Int(buffer.format.channelCount) {
                destination[channel].update(
                    from: source[channel].advanced(by: Int(skip)),
                    count: Int(take)
                )
            }
            slice.frameLength = AVAudioFrameCount(take)
            try outputFile.write(from: slice)
        }
    }

    /// An offline engine: player -> AUSoundIsolation -> output.
    private static func makeEngine(
        format: AVAudioFormat,
        mix: Float
    ) throws -> (AVAudioEngine, AVAudioPlayerNode) {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let effect = AVAudioUnitEffect(audioComponentDescription: description)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.attach(effect)
        engine.connect(player, to: effect, format: format)
        engine.connect(effect, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(
            .offline,
            format: format,
            maximumFrameCount: renderChunk
        )

        // connect/play/auAudioUnit rather than their macOS 27 replacements,
        // which koom's macOS 26 deployment target can't use.
        do {
            var sawModel = false
            for parameter in effect.auAudioUnit.parameterTree?.allParameters
                ?? []
            {
                switch parameter.displayName {
                case "Wet/Dry Mix":
                    parameter.value = mix
                case "Sound to Isolate":
                    // valueStrings: ["High Quality Voice", "Voice"]
                    guard
                        let index = parameter.valueStrings?.firstIndex(
                            of: "High Quality Voice"
                        )
                    else {
                        throw IsolationError(
                            "The high-quality voice isolation model isn't available on this Mac."
                        )
                    }
                    parameter.value = AUValue(index)
                    sawModel = true
                default:
                    break
                }
            }
            guard sawModel else {
                throw IsolationError(
                    "Voice isolation has no model parameter on this Mac."
                )
            }
        }

        try engine.start()
        return (engine, player)
    }

    /// Renders `frameCount` output frames, handing each chunk to `consume`.
    private static func render(
        _ engine: AVAudioEngine,
        frameCount: AVAudioFramePosition,
        consume: (AVAudioPCMBuffer) throws -> Void
    ) throws {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat,
                frameCapacity: renderChunk
            )
        else {
            throw IsolationError("Could not allocate an audio buffer.")
        }
        var rendered: AVAudioFramePosition = 0
        while rendered < frameCount {
            let chunk = AVAudioFrameCount(
                min(AVAudioFramePosition(renderChunk), frameCount - rendered)
            )
            let status = try engine.renderOffline(chunk, to: buffer)
            guard status == .success else {
                throw IsolationError(
                    "Voice isolation rendering failed (status \(status.rawValue))."
                )
            }
            rendered += AVAudioFramePosition(buffer.frameLength)
            try consume(buffer)
        }
    }

    /// Feeds a unit impulse through a dry (mix 0) engine and returns the
    /// frame at which it comes out: the unit's real processing delay.
    private static func measureLatency(
        format: AVAudioFormat
    ) throws -> AVAudioFramePosition {
        let length = AVAudioFrameCount(format.sampleRate)  // 1 s is ample
        guard
            let impulse = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: length
            ),
            let samples = impulse.floatChannelData
        else {
            throw IsolationError("Could not allocate an audio buffer.")
        }
        impulse.frameLength = length
        for channel in 0..<Int(format.channelCount) {
            samples[channel].update(repeating: 0, count: Int(length))
            samples[channel][0] = 1
        }

        let (engine, player) = try makeEngine(format: format, mix: 0)
        defer { engine.stop() }
        player.scheduleBuffer(impulse)
        player.play()

        var position: AVAudioFramePosition = 0
        var peakPosition: AVAudioFramePosition = 0
        var peak: Float = 0
        try render(engine, frameCount: AVAudioFramePosition(length)) { buffer in
            guard let channel = buffer.floatChannelData?[0] else { return }
            for index in 0..<Int(buffer.frameLength)
            where abs(channel[index]) > peak {
                peak = abs(channel[index])
                peakPosition = position + AVAudioFramePosition(index)
            }
            position += AVAudioFramePosition(buffer.frameLength)
        }
        guard peak > 0.5 else {
            throw IsolationError(
                "Voice isolation latency calibration failed."
            )
        }
        return peakPosition
    }
}
