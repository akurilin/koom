@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Pulls mic audio out of a finalized koom `.mp4` as a 16 kHz mono
/// float PCM buffer, ready to hand to WhisperKit without any extra
/// resampling step.
///
/// The output format is what Whisper's CoreML models were trained
/// against. Feeding them anything else silently produces garbage
/// transcripts, so we pin the conversion format explicitly here
/// instead of trusting the source file's native sample rate.
///
/// No ffmpeg, no temporary WAV files: `AVAssetReader` can do the
/// resample/downmix in a single pass entirely in memory.
enum AudioExtractor {
    /// Extracts the first audio track from `fileURL` and returns it
    /// as a contiguous 16 kHz mono `[Float]` buffer. Returns `nil`
    /// if the asset has no audio track, if the reader can't be
    /// created, or if reading fails partway through — all of those
    /// are non-fatal signals to "skip auto-titling for this file"
    /// rather than errors to surface to the user.
    static func extractMono16kFloatPCM(from fileURL: URL) async -> [Float]? {
        let asset = AVURLAsset(url: fileURL)

        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            AppLog.info(
                "AudioExtractor: loadTracks failed for \(fileURL.lastPathComponent): \(error.localizedDescription)"
            )
            return nil
        }

        guard let track = audioTracks.first else {
            return nil
        }

        // 16 kHz / mono / 32-bit float / little-endian / packed /
        // interleaved. AVAssetReader will resample and downmix as
        // needed to honor these settings.
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            AppLog.info(
                "AudioExtractor: AVAssetReader init failed for \(fileURL.lastPathComponent): \(error.localizedDescription)"
            )
            return nil
        }

        let trackOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: outputSettings
        )
        trackOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(trackOutput) else {
            AppLog.info(
                "AudioExtractor: reader cannot accept the requested output for \(fileURL.lastPathComponent)"
            )
            return nil
        }
        reader.add(trackOutput)

        guard reader.startReading() else {
            AppLog.info(
                "AudioExtractor: startReading failed for \(fileURL.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown")"
            )
            return nil
        }

        var samples: [Float] = []
        // Reserve capacity for ~5 minutes of 16 kHz audio so typical
        // koom recordings don't thrash the underlying buffer while
        // we're appending from each sample block.
        samples.reserveCapacity(16_000 * 60 * 5)

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sampleBuffer) }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }

            let totalLength = CMBlockBufferGetDataLength(blockBuffer)
            if totalLength == 0 { continue }

            // Ask the block buffer to hand us a pointer to a
            // contiguous run of samples. CMBlockBufferGetDataPointer
            // returns ranges without copying when the underlying
            // storage is already contiguous, which it is here
            // because we asked AVAssetReader for interleaved PCM.
            var lengthAtOffset = 0
            var totalLengthOut = 0
            var dataPointer: UnsafeMutablePointer<CChar>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLengthOut,
                dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr, let dataPointer else {
                AppLog.info(
                    "AudioExtractor: CMBlockBufferGetDataPointer failed with status \(status); skipping sample."
                )
                continue
            }

            let floatCount = totalLength / MemoryLayout<Float>.size
            dataPointer.withMemoryRebound(to: Float.self, capacity: floatCount) { typed in
                let buffer = UnsafeBufferPointer(start: typed, count: floatCount)
                samples.append(contentsOf: buffer)
            }
        }

        switch reader.status {
        case .completed:
            return samples
        case .failed, .cancelled, .reading, .unknown:
            AppLog.info(
                "AudioExtractor: reader ended in status \(reader.status.rawValue) for \(fileURL.lastPathComponent): \(reader.error?.localizedDescription ?? "no error")"
            )
            return samples.isEmpty ? nil : samples
        @unknown default:
            return samples.isEmpty ? nil : samples
        }
    }
}
