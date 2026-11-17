import Foundation

/// Best-effort audio cleanup for finalized recordings: noise removal, then
/// loudness normalization, in one audio re-encode. Video passes through
/// untouched. Any failure keeps the original file so an upload is never
/// blocked.
///
/// 1. Extract the microphone track as mono 48 kHz float WAV, padded with
///    silence so sample 0 lines up with the video's time zero (recordings
///    often start their audio a little after the video).
/// 2. Remove noise with the selected model. If it fails, fall back to Apple
///    Voice Isolation, then to the unprocessed audio.
/// 3. Apply one fixed gain to -16 LUFS and catch the peaks with a true-peak
///    limiter at -1.5 dBTP, measuring once more to make up what the
///    limiter took off.
/// 4. Encode AAC and mux it with the original video stream.
///
/// The limiter is what lets the gain actually reach the target: the old
/// peak-capped fixed gain left most recordings untouched, because a single
/// loud transient used up all the headroom (13 of 20 test clips in the
/// audio lab).
enum AudioCleanup {
    static let targetIntegratedLoudness = -16.0
    static let targetTruePeak = -1.5
    /// Limiting speech takes some loudness off; make it up when the result
    /// lands more than this far below the target.
    private static let makeupThresholdLU = 0.3

    struct LoudnessMeasurement: Equatable {
        let integratedLoudness: Double
        let truePeak: Double
        let loudnessRange: Double
    }

    /// Returns true when the original file was replaced with the cleaned
    /// copy.
    @discardableResult
    static func cleanRecording(
        at originalFileURL: URL,
        noiseRemoval: NoiseRemovalPlan
    ) async -> Bool {
        let name = originalFileURL.lastPathComponent
        guard let ffmpegURL = RecordingOptimizer.findFFmpegExecutable() else {
            AppLog.info("Audio cleanup skipped for \(name): ffmpeg was not found.")
            return false
        }

        let workDirectory = originalFileURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".koom-audio-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        do {
            try FileManager.default.createDirectory(
                at: workDirectory,
                withIntermediateDirectories: true
            )
            let extractedURL = workDirectory.appendingPathComponent("audio.wav")
            do {
                try await extractAudio(
                    from: originalFileURL,
                    to: extractedURL,
                    ffmpegURL: ffmpegURL
                )
            } catch {
                // Expected for recordings without a microphone track.
                AppLog.info(
                    "Audio cleanup skipped for \(name): no audio could be extracted: \(error.localizedDescription)"
                )
                return false
            }

            let started = Date()
            let (denoisedURL, appliedPlan) = await removeNoise(
                from: extractedURL,
                plan: noiseRemoval,
                workDirectory: workDirectory,
                recordingName: name
            )
            AppLog.info(
                "Noise removal for \(name): requested=\(noiseRemoval.logDescription); applied=\(appliedPlan); seconds=\(String(format: "%.1f", Date().timeIntervalSince(started)))"
            )

            let leveledURL = workDirectory.appendingPathComponent("leveled.wav")
            try await normalizeLoudness(
                of: denoisedURL,
                to: leveledURL,
                ffmpegURL: ffmpegURL,
                recordingName: name
            )

            let outputURL = workDirectory.appendingPathComponent(
                originalFileURL.deletingPathExtension().lastPathComponent
                    + "-clean.mp4"
            )
            try await mux(
                video: originalFileURL,
                audio: leveledURL,
                to: outputURL,
                ffmpegURL: ffmpegURL
            )
            _ = try FileManager.default.replaceItemAt(
                originalFileURL,
                withItemAt: outputURL
            )
        } catch {
            AppLog.error(
                "Audio cleanup failed for \(name): \(error.localizedDescription)"
            )
            return false
        }

        AppLog.info("Audio cleanup replaced \(name).")
        return true
    }

    // MARK: - Steps

    private static func extractAudio(
        from inputURL: URL,
        to outputURL: URL,
        ffmpegURL: URL
    ) async throws {
        try await runFFmpeg(
            ffmpegURL,
            [
                "-i", inputURL.path,
                "-map", "0:a:0",
                // Pad the start so the audio begins at the video's time
                // zero; muxing back at offset 0 then keeps lip sync.
                "-af", "aresample=async=1:first_pts=0",
                "-ac", "1",
                "-ar", "48000",
                "-c:a", "pcm_f32le",
                outputURL.path,
            ]
        )
    }

    /// Returns the cleaned file and a description of what actually ran.
    private static func removeNoise(
        from inputURL: URL,
        plan: NoiseRemovalPlan,
        workDirectory: URL,
        recordingName: String
    ) async -> (URL, String) {
        let outputURL = workDirectory.appendingPathComponent("denoised.wav")

        if case .helper(let runtime) = plan {
            do {
                _ = try await ProcessRunner.run(
                    runtime.pythonURL,
                    arguments: [
                        runtime.scriptURL.path, inputURL.path, outputURL.path,
                    ],
                    environment: runtime.environment,
                    currentDirectoryURL: runtime.workingDirectoryURL
                )
                return (outputURL, runtime.displayName)
            } catch {
                AppLog.error(
                    "Noise removal with \(runtime.displayName) failed for \(recordingName); falling back to Apple Voice Isolation: \(error.localizedDescription)"
                )
            }
        }

        if case .off = plan {
            return (inputURL, "off")
        }

        do {
            try await Task.detached(priority: .utility) {
                try AppleVoiceIsolation.process(
                    input: inputURL,
                    output: outputURL
                )
            }.value
            return (outputURL, "Apple Voice Isolation")
        } catch {
            AppLog.error(
                "Apple Voice Isolation failed for \(recordingName); keeping the noisy audio: \(error.localizedDescription)"
            )
            return (inputURL, "none (all methods failed)")
        }
    }

    private static func normalizeLoudness(
        of inputURL: URL,
        to outputURL: URL,
        ffmpegURL: URL,
        recordingName: String
    ) async throws {
        let measurement = try await measureLoudness(
            of: inputURL,
            ffmpegURL: ffmpegURL
        )
        guard measurement.integratedLoudness.isFinite else {
            AppLog.info(
                "Loudness normalization skipped for \(recordingName): audio is silent."
            )
            try await applyGain(0, limit: false, to: inputURL, output: outputURL, ffmpegURL: ffmpegURL)
            return
        }

        var gain = targetIntegratedLoudness - measurement.integratedLoudness
        try await applyGain(gain, limit: true, to: inputURL, output: outputURL, ffmpegURL: ffmpegURL)

        let result = try await measureLoudness(
            of: outputURL,
            ffmpegURL: ffmpegURL
        )
        let shortfall = targetIntegratedLoudness - result.integratedLoudness
        if shortfall.isFinite, shortfall > makeupThresholdLU {
            gain += shortfall
            try await applyGain(gain, limit: true, to: inputURL, output: outputURL, ffmpegURL: ffmpegURL)
        }

        AppLog.info(
            "Loudness normalization for \(recordingName): input \(format(measurement.integratedLoudness)) LUFS, \(format(measurement.truePeak)) dBTP; gain \(format(gain)) dB; first pass \(format(result.integratedLoudness)) LUFS; target \(format(targetIntegratedLoudness)) LUFS."
        )
    }

    private static func applyGain(
        _ gain: Double,
        limit: Bool,
        to inputURL: URL,
        output outputURL: URL,
        ffmpegURL: URL
    ) async throws {
        try await runFFmpeg(
            ffmpegURL,
            [
                "-i", inputURL.path,
                "-af", limit ? gainFilter(gain: gain) : "anull",
                "-c:a", "pcm_f32le",
                "-ar", "48000",
                outputURL.path,
            ]
        )
    }

    private static func mux(
        video videoURL: URL,
        audio audioURL: URL,
        to outputURL: URL,
        ffmpegURL: URL
    ) async throws {
        try await runFFmpeg(
            ffmpegURL,
            [
                "-i", videoURL.path,
                "-i", audioURL.path,
                "-map", "0:v?",
                "-map", "1:a:0",
                "-c:v", "copy",
                "-c:a", "aac",
                "-b:a", "192k",
                "-ar", "48000",
                // ffmpeg's mono-to-stereo upmix keeps the measured loudness.
                "-ac", "2",
                "-movflags", "+faststart",
                outputURL.path,
            ]
        )
    }

    /// Fixed gain, then a true-peak limiter: oversampled 4x so it also
    /// catches peaks between samples, with its latency compensated.
    static func gainFilter(gain: Double) -> String {
        let limit = pow(10, targetTruePeak / 20)
        return
            "volume=\(format(gain))dB,aresample=192000,alimiter=limit=\(String(format: "%.4f", limit)):attack=5:release=50:level=0:latency=1,aresample=48000"
    }

    // MARK: - Measurement

    static func measureLoudness(
        of inputURL: URL,
        ffmpegURL: URL
    ) async throws -> LoudnessMeasurement {
        // loudnorm prints its measurement JSON at info loglevel on stderr.
        let output = try await ProcessRunner.run(
            ffmpegURL,
            arguments: [
                "-nostdin", "-hide_banner", "-nostats",
                "-i", inputURL.path,
                "-map", "0:a:0",
                "-af", "loudnorm=print_format=json",
                "-f", "null", "-",
            ]
        )
        guard
            let measurement = parseLoudnessMeasurement(
                fromFFmpegStderr: output.stderr
            )
        else {
            throw CleanupError("ffmpeg did not report a loudness measurement.")
        }
        return measurement
    }

    /// Extracts the loudnorm measurement from stderr, which ends with a JSON
    /// object whose values are strings (possibly "-inf" for silence).
    static func parseLoudnessMeasurement(
        fromFFmpegStderr stderr: String
    ) -> LoudnessMeasurement? {
        guard let opening = stderr.range(of: "{", options: .backwards),
            let closing = stderr.range(of: "}", options: .backwards),
            opening.lowerBound < closing.upperBound
        else {
            return nil
        }
        let jsonData = Data(
            stderr[opening.lowerBound..<closing.upperBound].utf8
        )
        guard
            let object = try? JSONSerialization.jsonObject(with: jsonData)
                as? [String: String]
        else {
            return nil
        }

        func value(_ key: String) -> Double? {
            object[key].flatMap(Double.init)
        }
        guard let integrated = value("input_i"),
            let truePeak = value("input_tp"),
            let range = value("input_lra")
        else {
            return nil
        }
        return LoudnessMeasurement(
            integratedLoudness: integrated,
            truePeak: truePeak,
            loudnessRange: range
        )
    }

    // MARK: - Helpers

    private struct CleanupError: LocalizedError {
        let errorDescription: String?

        init(_ message: String) {
            errorDescription = message
        }
    }

    private static func runFFmpeg(
        _ ffmpegURL: URL,
        _ arguments: [String]
    ) async throws {
        _ = try await ProcessRunner.run(
            ffmpegURL,
            arguments: ["-y", "-nostdin", "-hide_banner", "-loglevel", "error"]
                + arguments
        )
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
