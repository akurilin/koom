import Foundation

/// Best-effort two-pass EBU R128 loudness normalization for finalized
/// recordings, so quiet narration lands at a consistent, audible level
/// before upload. Video passes through untouched; only audio is re-encoded.
///
/// Pass 1 measures the file's integrated loudness with ffmpeg's `loudnorm`
/// filter; pass 2 applies one constant gain for the whole file. No compressor,
/// limiter, or loudnorm processing is used in pass 2: if the full target boost
/// would clip, the fixed gain is reduced for the entire clip instead of
/// dynamically ducking later words.
enum LoudnessNormalizer {
    /// Spoken-word web target. YouTube normalizes to about -14 LUFS;
    /// -16 keeps a little headroom for voice.
    private static let targetIntegratedLoudness = -16.0
    private static let targetTruePeak = -1.5
    /// Recordings already within this distance of the target are left
    /// untouched to avoid a pointless audio re-encode.
    private static let skipThresholdLU = 1.0
    private static let minimumAppliedGainDB = 0.1

    struct LoudnessMeasurement: Equatable {
        let integratedLoudness: Double
        let truePeak: Double
        let loudnessRange: Double
    }

    /// Returns true when the original file was replaced with a normalized
    /// copy. Keeps the original on any failure so an upload is never blocked.
    @discardableResult
    static func normalizeRecording(at originalFileURL: URL) async -> Bool {
        guard let ffmpegURL = RecordingOptimizer.findFFmpegExecutable() else {
            AppLog.info(
                "Loudness normalization skipped for \(originalFileURL.lastPathComponent): ffmpeg was not found."
            )
            return false
        }

        let measurement: LoudnessMeasurement
        do {
            measurement = try await measureLoudness(
                of: originalFileURL,
                ffmpegURL: ffmpegURL
            )
        } catch {
            // Expected for recordings without an audio track, in addition
            // to genuine failures; either way the original stays as-is.
            AppLog.info(
                "Loudness normalization skipped for \(originalFileURL.lastPathComponent): measurement failed: \(error.localizedDescription)"
            )
            return false
        }

        AppLog.info(
            "Loudness measurement for \(originalFileURL.lastPathComponent): integrated=\(measurement.integratedLoudness) LUFS; truePeak=\(measurement.truePeak) dBTP; range=\(measurement.loudnessRange) LU; target=\(targetIntegratedLoudness) LUFS"
        )

        guard measurement.integratedLoudness.isFinite else {
            AppLog.info(
                "Loudness normalization skipped for \(originalFileURL.lastPathComponent): audio is silent."
            )
            return false
        }

        let distanceFromTarget = abs(
            measurement.integratedLoudness - targetIntegratedLoudness
        )
        guard distanceFromTarget > skipThresholdLU else {
            AppLog.info(
                "Loudness normalization skipped for \(originalFileURL.lastPathComponent): already within \(skipThresholdLU) LU of target."
            )
            return false
        }

        let gain = normalizationGain(for: measurement)
        guard abs(gain) >= minimumAppliedGainDB else {
            AppLog.info(
                "Loudness normalization skipped for \(originalFileURL.lastPathComponent): fixed-gain boost has no true-peak headroom (desired \(format(targetIntegratedLoudness - measurement.integratedLoudness)) dB; truePeak \(measurement.truePeak) dBTP; ceiling \(targetTruePeak) dBTP)."
            )
            return false
        }

        let tempDirectory = originalFileURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".koom-normalize-\(UUID().uuidString)",
                isDirectory: true
            )
        let outputURL = tempDirectory.appendingPathComponent(
            originalFileURL.deletingPathExtension().lastPathComponent
                + "-normalized.mp4"
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        do {
            try FileManager.default.createDirectory(
                at: tempDirectory,
                withIntermediateDirectories: true
            )
            try await applyNormalization(
                to: originalFileURL,
                outputURL: outputURL,
                gain: gain,
                ffmpegURL: ffmpegURL
            )
            _ = try FileManager.default.replaceItemAt(
                originalFileURL,
                withItemAt: outputURL
            )
        } catch {
            AppLog.error(
                "Loudness normalization failed for \(originalFileURL.lastPathComponent): \(error.localizedDescription)"
            )
            return false
        }

        AppLog.info(
            "Loudness normalization replaced \(originalFileURL.lastPathComponent): integrated \(measurement.integratedLoudness) LUFS; target \(targetIntegratedLoudness) LUFS; fixed gain \(format(gain)) dB."
        )
        return true
    }

    private static func measureLoudness(
        of inputURL: URL,
        ffmpegURL: URL
    ) async throws -> LoudnessMeasurement {
        // loudnorm prints its measurement JSON at info loglevel on stderr,
        // so this pass cannot use -loglevel error.
        let arguments = [
            "-y",
            "-nostdin",
            "-hide_banner",
            "-nostats",
            "-i",
            inputURL.path,
            "-map",
            "0:a:0",
            "-af",
            measurementFilter(),
            "-f",
            "null",
            "-",
        ]
        let stderr = try await runFFmpeg(
            executableURL: ffmpegURL,
            arguments: arguments
        )
        guard let measurement = parseLoudnessMeasurement(fromFFmpegStderr: stderr)
        else {
            throw LoudnessNormalizerError.unparsableMeasurement
        }
        return measurement
    }

    private static func applyNormalization(
        to inputURL: URL,
        outputURL: URL,
        gain: Double,
        ffmpegURL: URL
    ) async throws {
        let arguments = [
            "-y",
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            inputURL.path,
            "-map",
            "0:v?",
            "-map",
            "0:a:0",
            "-c:v",
            "copy",
            "-af",
            applyFilter(gain: gain),
            "-c:a",
            "aac",
            "-b:a",
            "192k",
            // Pin normalized audio to the capture rate for stable output.
            "-ar",
            "48000",
            "-movflags",
            "+faststart",
            outputURL.path,
        ]
        AppLog.info(
            "Loudness normalization ffmpeg execution: command=\(RecordingOptimizer.formatCommand(executableURL: ffmpegURL, arguments: arguments))"
        )
        _ = try await runFFmpeg(
            executableURL: ffmpegURL,
            arguments: arguments
        )
    }

    private static func measurementFilter() -> String {
        "loudnorm=print_format=json"
    }

    /// Returns one fixed gain for the whole recording. Positive boosts are
    /// capped by true-peak headroom so clipping risk is handled globally, not
    /// with a dynamic limiter.
    static func normalizationGain(for measurement: LoudnessMeasurement) -> Double {
        let desiredGain =
            targetIntegratedLoudness
            - measurement.integratedLoudness
        guard desiredGain > 0, measurement.truePeak.isFinite else {
            return desiredGain
        }
        let peakHeadroom = targetTruePeak - measurement.truePeak
        return min(desiredGain, max(0.0, peakHeadroom))
    }

    static func applyFilter(gain: Double) -> String {
        "volume=\(format(gain))dB"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// Extracts the loudnorm measurement from pass-1 stderr, which ends with
    /// a JSON object whose values are strings (possibly "-inf" for silence).
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

    private static func runFFmpeg(
        executableURL: URL,
        arguments: [String]
    ) async throws -> String {
        let process = Process()
        let errorPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = errorPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let stderrData = errorPipe.fileHandleForReading
                    .readDataToEndOfFile()
                let stderr = String(decoding: stderrData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if process.terminationStatus == 0 {
                    continuation.resume(returning: stderr)
                } else {
                    continuation.resume(
                        throwing: LoudnessNormalizerError.ffmpegFailed(
                            stderr.isEmpty
                                ? "ffmpeg exited with status \(process.terminationStatus)."
                                : stderr
                        )
                    )
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private enum LoudnessNormalizerError: LocalizedError {
    case unparsableMeasurement
    case ffmpegFailed(String)

    var errorDescription: String? {
        switch self {
        case .unparsableMeasurement:
            return "ffmpeg did not report a loudnorm measurement."
        case .ffmpegFailed(let message):
            return message
        }
    }
}
