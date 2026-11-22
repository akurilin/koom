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
/// 3. Apply fixed gain toward the loudness target. Limit peaks at -1.5 dBTP
///    and measure again to see if the limiter reduced overall loudness.
/// 4. Encode AAC and mux it with the original video stream.
///
/// The limiter is what lets the gain actually reach the target: the old
/// peak-capped fixed gain left most recordings untouched, because a single
/// loud transient used up all the headroom (13 of 20 test clips in the
/// audio lab).
enum AudioCleanup {
    static let targetIntegratedLoudness = -20.5
    static let targetTruePeak = -1.5
    private static let extractedAudioFilename = "01-extracted.wav"
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
        do {
            try await processRecording(
                videoURL: originalFileURL,
                outputURL: originalFileURL,
                extractedAudioURL: nil,
                noiseRemoval: noiseRemoval
            )
            AppLog.info("Audio cleanup replaced \(name).")
            return true
        } catch {
            AppLog.error("Audio cleanup failed for \(name): \(error.localizedDescription)")
            return false
        }
    }

    static func reprocessRecording(
        at videoURL: URL,
        noiseRemoval: NoiseRemovalPlan
    ) async throws -> URL {
        let archiveURL = stageArchiveURL(for: videoURL)
        let extractedAudioURL = archiveURL.appendingPathComponent(extractedAudioFilename)
        guard FileManager.default.isReadableFile(atPath: extractedAudioURL.path) else {
            throw CleanupError("This recording has no saved microphone WAV.")
        }

        // Keep test copies below the archive so catch-up uploads skip them.
        let outputDirectory = archiveURL.appendingPathComponent("reprocessed", isDirectory: true)
        let filename = RecordingSessionStore.makeOutputFilename()
        let stem = (filename as NSString).deletingPathExtension
        let runID = UUID().uuidString.prefix(8)
        let outputURL = outputDirectory.appendingPathComponent("\(stem)-\(runID).mp4")
        try await processRecording(
            videoURL: videoURL,
            outputURL: outputURL,
            extractedAudioURL: extractedAudioURL,
            noiseRemoval: noiseRemoval
        )
        return outputURL
    }

    private static func processRecording(
        videoURL: URL,
        outputURL: URL,
        extractedAudioURL: URL?,
        noiseRemoval: NoiseRemovalPlan
    ) async throws {
        let name = videoURL.lastPathComponent
        guard let ffmpegURL = RecordingOptimizer.findFFmpegExecutable() else {
            throw CleanupError("Could not find FFmpeg.")
        }

        let runID = UUID().uuidString
        let workDirectory = outputURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".koom-audio-\(runID)",
                isDirectory: true
            )
        var completedStages: [URL] = []
        defer {
            // Keep finished stages even if a later step fails.
            saveStages(completedStages, for: outputURL, in: workDirectory, runID: runID)
            try? FileManager.default.removeItem(at: workDirectory)
        }

        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let extractedURL: URL
        if let extractedAudioURL {
            extractedURL = extractedAudioURL
        } else {
            extractedURL = workDirectory.appendingPathComponent(extractedAudioFilename)
            try await extractAudio(from: videoURL, to: extractedURL, ffmpegURL: ffmpegURL)
            completedStages.append(extractedURL)
        }

        let started = Date()
        let (denoisedURL, appliedPlan) = await removeNoise(
            from: extractedURL,
            plan: noiseRemoval,
            workDirectory: workDirectory,
            recordingName: name
        )
        if denoisedURL != extractedURL {
            completedStages.append(denoisedURL)
        }
        AppLog.info(
            "Noise removal for \(name): requested=\(noiseRemoval.logDescription); applied=\(appliedPlan); seconds=\(String(format: "%.1f", Date().timeIntervalSince(started)))"
        )

        let leveledURL = workDirectory.appendingPathComponent("03-leveled.wav")
        try await normalizeLoudness(
            of: denoisedURL,
            to: leveledURL,
            ffmpegURL: ffmpegURL,
            recordingName: name
        )
        completedStages.append(leveledURL)

        let muxedURL = workDirectory.appendingPathComponent("clean.mp4")
        try await mux(video: videoURL, audio: leveledURL, to: muxedURL, ffmpegURL: ffmpegURL)
        if outputURL == videoURL {
            _ = try FileManager.default.replaceItemAt(
                videoURL,
                withItemAt: muxedURL
            )
        } else {
            try FileManager.default.moveItem(at: muxedURL, to: outputURL)
        }
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
        let outputURL = workDirectory.appendingPathComponent("02-denoised.wav")

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

    private static func stageArchiveURL(for recordingURL: URL) -> URL {
        let folderName = recordingURL.deletingPathExtension().lastPathComponent + "-audio"
        return recordingURL.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
    }

    private static func saveStages(
        _ stages: [URL],
        for recordingURL: URL,
        in workDirectory: URL,
        runID: String
    ) {
        guard !stages.isEmpty else { return }

        let fileManager = FileManager.default
        let archiveURL = stageArchiveURL(for: recordingURL)
        // Keep earlier runs separate when the same file is processed again.
        let destination =
            fileManager.fileExists(atPath: archiveURL.path)
            ? archiveURL.deletingLastPathComponent().appendingPathComponent(
                "\(archiveURL.lastPathComponent)-\(runID)", isDirectory: true
            )
            : archiveURL
        let stagingURL = workDirectory.appendingPathComponent("stages", isDirectory: true)

        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
            for stage in stages {
                try fileManager.moveItem(
                    at: stage,
                    to: stagingURL.appendingPathComponent(stage.lastPathComponent)
                )
            }
            try fileManager.moveItem(at: stagingURL, to: destination)
            AppLog.info("Saved audio stages at \(destination.path).")
        } catch {
            AppLog.error("Could not save audio stages for \(recordingURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

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
