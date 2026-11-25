import AVFoundation
import Accelerate
import os

// Each source analyzes audio on its sample queue. The overlay reads the latest levels.
final class MicrophoneSpectrum: @unchecked Sendable {
    private static let windowSize = 2_048
    private static let bandCount = 24
    private static let lowestFrequency = 100.0
    private static let highestFrequency = 10_000.0
    private static let noiseFloorDB: Float = -62
    private static let fullBarDB: Float = -14
    private static let attack: Float = 0.72
    private static let release: Float = 0.32
    private static let signalTimeout: Duration = .milliseconds(250)
    private static let silence = [Float](repeating: 0, count: bandCount)

    private struct Reading {
        let levels: [Float]
        let time: ContinuousClock.Instant
    }

    private let reading = OSAllocatedUnfairLock<Reading?>(initialState: nil)
    private let transform: vDSP.DiscreteFourierTransform<Float>
    private let window = vDSP.window(
        ofType: Float.self,
        usingSequence: .hanningDenormalized,
        count: windowSize,
        isHalfWindow: false
    )
    private let zeroImaginary = [Float](repeating: 0, count: windowSize)
    private var samples = [Float](repeating: 0, count: windowSize)
    private var sampleCount = 0
    private var sampleRate = 0.0
    private var bands: [Range<Int>] = []
    private var levels = silence

    init?() {
        guard
            let transform = try? vDSP.DiscreteFourierTransform(
                count: Self.windowSize,
                direction: .forward,
                transformType: .complexComplex,
                ofType: Float.self
            )
        else { return nil }
        self.transform = transform
    }

    var currentLevels: [Float] {
        let latest = reading.withLock { $0 }
        guard let latest, ContinuousClock.now - latest.time < Self.signalTimeout else {
            return Self.silence
        }
        return latest.levels
    }

    func reset() {
        sampleCount = 0
        levels = Self.silence
        reading.withLock { $0 = nil }
    }

    func consume(_ sampleBuffer: CMSampleBuffer) {
        guard
            let description = sampleBuffer.formatDescription,
            let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
            stream.pointee.mSampleRate.isFinite, stream.pointee.mSampleRate > 0,
            stream.pointee.mChannelsPerFrame > 0
        else { return }
        let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: nil)
            .map { AVAudioChannelLayout(layout: $0) }
        guard let format = AVAudioFormat(streamDescription: stream, channelLayout: layout) else { return }

        // Read the PCM in place with its original channel layout and sample type.
        try? sampleBuffer.withAudioBufferList { buffers, _ in
            guard
                let pcm = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: buffers.unsafePointer
                )
            else { return }

            if format.sampleRate != sampleRate {
                sampleRate = format.sampleRate
                bands = Self.frequencyBands(sampleRate: sampleRate)
                reset()
            }

            if let channels = pcm.floatChannelData {
                collect(channels, from: pcm) { $0 }
            } else if let channels = pcm.int16ChannelData {
                collect(channels, from: pcm) { Float($0) / -Float(Int16.min) }
            } else if let channels = pcm.int32ChannelData {
                collect(channels, from: pcm) { Float($0) / -Float(Int32.min) }
            }
        }
    }

    private func collect<Sample>(
        _ channels: UnsafePointer<UnsafeMutablePointer<Sample>>,
        from pcm: AVAudioPCMBuffer,
        toFloat: (Sample) -> Float
    ) {
        let channelCount = Int(pcm.format.channelCount)
        let stride = pcm.stride
        for frame in 0..<Int(pcm.frameLength) {
            let monoSample =
                (0..<channelCount).reduce(Float.zero) { sum, channel in
                    sum + toFloat(channels[channel][frame * stride])
                } / Float(channelCount)
            samples[sampleCount] = monoSample.isFinite ? monoSample : 0
            sampleCount += 1

            // Join short capture buffers so each transform has the same frequency resolution.
            if sampleCount == Self.windowSize {
                publishLevels()
                sampleCount = 0
            }
        }
    }

    private static func frequencyBands(sampleRate: Double) -> [Range<Int>] {
        let binWidth = sampleRate / Double(windowSize)
        let highestBin = windowSize / 2 - 1
        let upperFrequency = min(highestFrequency, sampleRate / 2)
        let lowerFrequency = min(lowestFrequency, upperFrequency)
        let ratio = upperFrequency / lowerFrequency
        let edges = (0...bandCount).map { edge in
            let frequency = lowerFrequency * pow(ratio, Double(edge) / Double(bandCount))
            return min(highestBin, max(1, Int((frequency / binWidth).rounded())))
        }
        return (0..<bandCount).map { index in
            edges[index]..<max(edges[index] + 1, edges[index + 1])
        }
    }

    private func publishLevels() {
        let windowed = vDSP.multiply(samples, window)
        let spectrum = transform.transform(real: windowed, imaginary: zeroImaginary)
        // A full-scale tone gives N/4 after Hann windowing and a forward transform.
        let fullScale = Float(Self.windowSize) / 4

        for (index, band) in bands.enumerated() {
            let peak = band.reduce(Float.zero) { peak, bin in
                max(peak, hypotf(spectrum.real[bin], spectrum.imaginary[bin]))
            }
            let decibels = 20 * log10f(peak / fullScale)
            let level = min(1, max(0, (decibels - Self.noiseFloorDB) / (Self.fullBarDB - Self.noiseFloorDB)))
            let response = level > levels[index] ? Self.attack : Self.release
            levels[index] += (level - levels[index]) * response
        }
        reading.withLock { $0 = Reading(levels: levels, time: .now) }
    }
}
