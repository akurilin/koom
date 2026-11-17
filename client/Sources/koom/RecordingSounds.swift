import AVFoundation
import Foundation

/// Short chimes for the recording controls, synthesized at launch.
///
/// The cues share one voice so they read as a family: start is a rising
/// G-major arpeggio, stop the same arpeggio falling, restart a quick
/// "rewind" run down followed by the start arpeggio, and pause/resume
/// a soft pitch glide down/up.
///
/// The microphone must never hear these, so `play` returns the instant
/// by which a cue has died away, and callers keep capture closed until
/// then: start and resume wait for that instant before samples flow;
/// stop and pause play only once samples have stopped flowing.
///
/// Cues follow the system "Play user interface sound effects" setting;
/// with it off, `play` is silent and returns immediately, so nothing
/// waits on a sound that never plays.
@MainActor
final class RecordingSounds {
    enum Cue: CaseIterable {
        case start
        case stop
        case restart
        case pause
        case resume
    }

    /// Allowance after a cue's last sample for output latency and room
    /// echo before the microphone may open.
    private static let captureMargin: Duration = .milliseconds(150)
    private static let volume: Float = 0.55

    private var players: [Cue: AVAudioPlayer] = [:]

    init() {
        for cue in Cue.allCases {
            do {
                let player = try AVAudioPlayer(
                    data: ChimeSynth.wavData(ChimeSynth.render(cue))
                )
                player.volume = Self.volume
                player.prepareToPlay()
                players[cue] = player
            } catch {
                AppLog.error(
                    "Could not prepare the \(cue) sound: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Plays `cue` and returns when it will be inaudible, so callers can
    /// hold the microphone closed until then.
    @discardableResult
    func play(_ cue: Cue) -> ContinuousClock.Instant {
        let now = ContinuousClock.now
        guard Self.userInterfaceSoundsEnabled else {
            AppLog.info("Skipped the \(cue) sound: UI sound effects are off.")
            return now
        }
        guard let player = players[cue] else { return now }
        player.currentTime = 0
        let started = player.play()
        AppLog.info("Played the \(cue) sound (started: \(started)).")
        return now + .seconds(player.duration) + Self.captureMargin
    }

    /// Sound settings > "Play user interface sound effects". The key is
    /// absent until the user first turns it off.
    private static var userInterfaceSoundsEnabled: Bool {
        UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled")
            as? Bool ?? true
    }
}

/// Additive synthesis for the cues: a soft glassy bell (harmonic
/// partials with a touch of detune, fast attack, exponential decay)
/// and a sine pitch glide.
private enum ChimeSynth {
    static let sampleRate = 48_000.0

    private enum Pitch {
        static let c5 = 523.25
        static let g5 = 783.99
        static let b5 = 987.77
        static let d6 = 1174.66
        static let e6 = 1318.51
    }

    private struct Bell {
        let onset: Double
        let frequency: Double
        /// Time constant of the exponential decay, in seconds.
        let decay: Double
        var gain = 1.0
    }

    /// Onset spacing of the arpeggio notes.
    private static let arpeggioStep = 0.065

    static func render(_ cue: RecordingSounds.Cue) -> [Float] {
        switch cue {
        case .start:
            return bells(arpeggio(at: 0, rising: true), peak: 0.9)

        case .stop:
            return bells(arpeggio(at: 0, rising: false), peak: 0.9)

        case .restart:
            let rewind = [Pitch.e6, Pitch.d6, Pitch.b5, Pitch.g5]
                .enumerated()
                .map { index, frequency in
                    Bell(
                        onset: Double(index) * 0.028,
                        frequency: frequency,
                        decay: 0.03,
                        gain: 0.45
                    )
                }
            return bells(rewind + arpeggio(at: 0.16, rising: true), peak: 0.9)

        case .pause:
            return glide(from: Pitch.g5, to: Pitch.c5, peak: 0.7)

        case .resume:
            return glide(from: Pitch.c5, to: Pitch.g5, peak: 0.7)
        }
    }

    /// G5–B5–D6, the last note ringing a little longer.
    private static func arpeggio(at start: Double, rising: Bool) -> [Bell] {
        let pitches = [Pitch.g5, Pitch.b5, Pitch.d6]
        return (rising ? pitches : pitches.reversed())
            .enumerated()
            .map { index, frequency in
                Bell(
                    onset: start + Double(index) * arpeggioStep,
                    frequency: frequency,
                    decay: index == pitches.count - 1 ? 0.09 : 0.06
                )
            }
    }

    private static func bells(_ notes: [Bell], peak: Float) -> [Float] {
        // (frequency ratio, relative amplitude, relative decay)
        let partials: [(Double, Double, Double)] = [
            (1.0, 1.0, 1.0),
            (1.003, 0.3, 1.0),
            (2.0, 0.28, 0.55),
            (3.0, 0.1, 0.35),
            (4.0, 0.04, 0.2),
        ]
        let length = notes.map { $0.onset + 4.5 * $0.decay }.max() ?? 0
        var samples = [Float](repeating: 0, count: Int(length * sampleRate))

        for note in notes {
            let firstSample = Int(note.onset * sampleRate)
            for index in firstSample..<samples.count {
                let time = Double(index - firstSample) / sampleRate
                var value = 0.0
                for (ratio, amplitude, decayScale) in partials {
                    value +=
                        amplitude
                        * exp(-time / (note.decay * decayScale))
                        * sin(2 * .pi * note.frequency * ratio * time)
                }
                samples[index] += Float(value * note.gain * attack(time))
            }
        }
        return finished(samples, peak: peak)
    }

    private static func glide(from startFrequency: Double, to endFrequency: Double, peak: Float)
        -> [Float]
    {
        let glideDuration = 0.11
        let decay = 0.06
        let length = glideDuration + 2.5 * decay
        var samples = [Float](repeating: 0, count: Int(length * sampleRate))
        var phase = 0.0

        for index in samples.indices {
            let time = Double(index) / sampleRate
            let progress = min(time / glideDuration, 1)
            let frequency = startFrequency * pow(endFrequency / startFrequency, progress)
            phase += 2 * .pi * frequency / sampleRate
            let envelope = attack(time) * exp(-max(time - 0.04, 0) / decay)
            samples[index] = Float(envelope * (sin(phase) + 0.15 * sin(2 * phase)))
        }
        return finished(samples, peak: peak)
    }

    /// Raised-cosine onset, short enough to read as a strike but long
    /// enough not to click.
    private static func attack(_ time: Double) -> Double {
        let attackDuration = 0.004
        guard time < attackDuration else { return 1 }
        return 0.5 - 0.5 * cos(.pi * time / attackDuration)
    }

    /// Normalizes to `peak` and fades the last 40 ms to silence so the
    /// truncated decay tail can't click.
    private static func finished(_ samples: [Float], peak: Float) -> [Float] {
        let maximum = samples.map(abs).max() ?? 0
        guard maximum > 0 else { return samples }
        let fadeLength = min(Int(0.04 * sampleRate), samples.count)
        let fadeStart = samples.count - fadeLength
        return samples.enumerated().map { index, sample in
            let fade =
                index < fadeStart
                ? 1 : Float(samples.count - index) / Float(fadeLength)
            return sample / maximum * peak * fade
        }
    }

    /// Mono 16-bit PCM WAV, which AVAudioPlayer can play from memory.
    static func wavData(_ samples: [Float]) -> Data {
        var data = Data()
        func append<Value: FixedWidthInteger>(_ value: Value) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytesPerSample = 2
        let dataSize = UInt32(samples.count * bytesPerSample)

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))  // fmt chunk size
        append(UInt16(1))  // PCM
        append(UInt16(1))  // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * UInt32(bytesPerSample))  // byte rate
        append(UInt16(bytesPerSample))  // block align
        append(UInt16(8 * bytesPerSample))  // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }
}
