// Offline voice isolation through Apple's AUSoundIsolation Audio Unit
// (aufx/vois/appl, macOS 13+; the high-quality model needs macOS 15+).
//
//   isolate <input.wav> <output.wav> [--mix <-100...100>] [--model hq|standard]
//
// --mix is the unit's Wet/Dry Mix: 100 keeps only the isolated voice,
// 0 passes the input through, values in between blend the two.
// Output is 32-bit float WAV in the input's format with the same frame
// count, time-aligned with the input. The audio lab pre-converts inputs
// to mono 48 kHz, which is the unit's native format.
//
// The unit reports zero latency but delays its output by a model-specific
// amount (measured on macOS 27: 4440 frames for the high-quality model,
// 2704 for the standard one), so each run measures it with an impulse
// before processing and trims it.

import AVFoundation

struct Options {
    var input: URL
    var output: URL
    var mix: Float = 100
    var model: String = "hq"
}

struct IsolateError: Error, CustomStringConvertible {
    let description: String
}

func parseOptions() -> Options {
    var args = Array(CommandLine.arguments.dropFirst())
    func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }
    guard args.count >= 2 else {
        fail("usage: isolate <input.wav> <output.wav> [--mix N] [--model hq|standard]")
    }
    var options = Options(
        input: URL(fileURLWithPath: args.removeFirst()),
        output: URL(fileURLWithPath: args.removeFirst())
    )
    while !args.isEmpty {
        let flag = args.removeFirst()
        guard !args.isEmpty else { fail("missing value for \(flag)") }
        let value = args.removeFirst()
        switch flag {
        case "--mix":
            guard let mix = Float(value), (-100...100).contains(mix) else {
                fail("--mix must be between -100 and 100")
            }
            options.mix = mix
        case "--model":
            guard value == "hq" || value == "standard" else {
                fail("--model must be hq or standard")
            }
            options.model = value
        default:
            fail("unknown option \(flag)")
        }
    }
    return options
}

let renderChunk: AVAudioFrameCount = 4096

/// An offline engine: player -> AUSoundIsolation -> output.
func makeEngine(
    format: AVAudioFormat,
    model: String,
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
    try engine.connectNode(player, to: effect, format: format)
    try engine.connectNode(effect, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(
        .offline,
        format: format,
        maximumFrameCount: renderChunk
    )

    try effect.withAUAudioUnit { unit in
        var sawModel = false
        for parameter in unit.parameterTree?.allParameters ?? [] {
            switch parameter.displayName {
            case "Wet/Dry Mix":
                parameter.value = mix
            case "Sound to Isolate":
                // valueStrings: ["High Quality Voice", "Voice"]
                let wanted = model == "hq" ? "High Quality Voice" : "Voice"
                guard let index = parameter.valueStrings?.firstIndex(of: wanted)
                else {
                    throw IsolateError(
                        description: "model \"\(wanted)\" is not available on this Mac"
                    )
                }
                parameter.value = AUValue(index)
                sawModel = true
            default:
                break
            }
        }
        guard sawModel else {
            throw IsolateError(description: "AUSoundIsolation has no model parameter")
        }
    }

    try engine.start()
    return (engine, player)
}

/// Renders `frameCount` output frames, handing each chunk to `consume`.
func render(
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
        throw IsolateError(description: "could not allocate render buffer")
    }
    var rendered: AVAudioFramePosition = 0
    while rendered < frameCount {
        let chunk = AVAudioFrameCount(
            min(AVAudioFramePosition(renderChunk), frameCount - rendered)
        )
        let status = try engine.renderOffline(chunk, to: buffer)
        guard status == .success else {
            throw IsolateError(description: "render status \(status.rawValue)")
        }
        rendered += AVAudioFramePosition(buffer.frameLength)
        try consume(buffer)
    }
}

/// Feeds a unit impulse through a dry (mix 0) engine and returns the frame
/// at which it comes out: the unit's real processing delay.
func measureLatency(format: AVAudioFormat, model: String) throws -> AVAudioFramePosition {
    let length = AVAudioFrameCount(format.sampleRate)  // 1 s is ample
    guard let impulse = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length),
        let samples = impulse.floatChannelData
    else {
        throw IsolateError(description: "could not allocate impulse")
    }
    impulse.frameLength = length
    for channel in 0..<Int(format.channelCount) {
        samples[channel].update(repeating: 0, count: Int(length))
        samples[channel][0] = 1
    }

    let (engine, player) = try makeEngine(format: format, model: model, mix: 0)
    defer { engine.stop() }
    player.scheduleBuffer(impulse)
    try player.playAudio()

    var position: AVAudioFramePosition = 0
    var peakPosition: AVAudioFramePosition = 0
    var peak: Float = 0
    try render(engine, frameCount: AVAudioFramePosition(length)) { buffer in
        let channel = buffer.floatChannelData![0]
        for index in 0..<Int(buffer.frameLength) where abs(channel[index]) > peak {
            peak = abs(channel[index])
            peakPosition = position + AVAudioFramePosition(index)
        }
        position += AVAudioFramePosition(buffer.frameLength)
    }
    guard peak > 0.5 else {
        throw IsolateError(description: "latency calibration impulse not found")
    }
    return peakPosition
}

func run(_ options: Options) throws {
    let inputFile = try AVAudioFile(forReading: options.input)
    let format = inputFile.processingFormat
    let inputFrames = inputFile.length
    let latency = try measureLatency(format: format, model: options.model)

    let (engine, player) = try makeEngine(
        format: format,
        model: options.model,
        mix: options.mix
    )
    defer { engine.stop() }
    player.scheduleFile(inputFile, at: nil)
    try player.playAudio()

    let outputFile = try AVAudioFile(
        forWriting: options.output,
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
            )
        else {
            throw IsolateError(description: "could not allocate slice")
        }
        for channel in 0..<Int(buffer.format.channelCount) {
            slice.floatChannelData![channel].update(
                from: buffer.floatChannelData![channel].advanced(by: Int(skip)),
                count: Int(take)
            )
        }
        slice.frameLength = AVAudioFrameCount(take)
        try outputFile.write(from: slice)
    }

    print("latency_frames=\(latency) frames=\(outputFile.length)")
}

do {
    try run(parseOptions())
} catch {
    FileHandle.standardError.write(Data("isolate failed: \(error)\n".utf8))
    exit(1)
}
