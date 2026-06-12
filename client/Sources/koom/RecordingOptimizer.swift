import Foundation

/// Best-effort local post-processing for finalized recordings.
enum RecordingOptimizer {
    private static let minimumSavingsRatio = 0.10

    @discardableResult
    static func optimizeRecording(at originalFileURL: URL) async -> Bool {
        let originalSizeBytes: Int64
        do {
            originalSizeBytes = try fileSize(of: originalFileURL)
        } catch {
            AppLog.error(
                "Could not inspect \(originalFileURL.lastPathComponent) before recording optimization: \(error.localizedDescription)"
            )
            return false
        }

        guard let ffmpegURL = findFFmpegExecutable() else {
            logDecision(
                for: originalFileURL,
                originalSizeBytes: originalSizeBytes,
                optimizedSizeBytes: nil,
                decision: "kept original local file because ffmpeg was not found."
            )
            return false
        }

        let tempDirectory = originalFileURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".koom-optimize-\(UUID().uuidString)",
                isDirectory: true
            )
        let outputURL = tempDirectory.appendingPathComponent(
            originalFileURL.deletingPathExtension().lastPathComponent
                + "-optimized.mp4"
        )
        defer { cleanupTemporaryDirectory(tempDirectory) }

        AppLog.info(
            "Recording optimization start: input=\(originalFileURL.path); originalBytes=\(originalSizeBytes); originalSize=\(formatBytes(originalSizeBytes)); output=\(outputURL.path); minimumSavings=10%"
        )

        do {
            try FileManager.default.createDirectory(
                at: tempDirectory,
                withIntermediateDirectories: true
            )
            try await runFFmpeg(
                executableURL: ffmpegURL,
                inputURL: originalFileURL,
                outputURL: outputURL
            )
        } catch {
            AppLog.error(
                "Recording optimization failed for \(originalFileURL.lastPathComponent): \(error.localizedDescription)"
            )
            return false
        }

        let optimizedSizeBytes: Int64
        do {
            optimizedSizeBytes = try fileSize(of: outputURL)
        } catch {
            AppLog.error(
                "Recording optimization produced an unreadable output for \(originalFileURL.lastPathComponent): \(error.localizedDescription)"
            )
            return false
        }
        AppLog.info(
            "Recording optimization output for \(originalFileURL.lastPathComponent): optimized size \(formatBytes(optimizedSizeBytes))."
        )

        let savingsRatio =
            Double(originalSizeBytes - optimizedSizeBytes)
            / Double(originalSizeBytes)
        guard optimizedSizeBytes > 0, savingsRatio >= minimumSavingsRatio else {
            logDecision(
                for: originalFileURL,
                originalSizeBytes: originalSizeBytes,
                optimizedSizeBytes: optimizedSizeBytes,
                decision:
                    "kept original local file because the optimized copy saved only \(formatPercent(savingsRatio)), below the 10% threshold."
            )
            return false
        }

        do {
            _ = try FileManager.default.replaceItemAt(
                originalFileURL,
                withItemAt: outputURL
            )
        } catch {
            AppLog.error(
                "Could not replace \(originalFileURL.lastPathComponent) with its optimized recording: \(error.localizedDescription)"
            )
            return false
        }

        logDecision(
            for: originalFileURL,
            originalSizeBytes: originalSizeBytes,
            optimizedSizeBytes: optimizedSizeBytes,
            decision:
                "replaced local file with optimized recording because it saved \(formatPercent(savingsRatio)), meeting the 10% threshold."
        )
        return true
    }

    private static func cleanupTemporaryDirectory(_ directoryURL: URL) {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private static func runFFmpeg(
        executableURL: URL,
        inputURL: URL,
        outputURL: URL
    ) async throws {
        let process = Process()
        let errorPipe = Pipe()

        process.executableURL = executableURL
        let arguments = [
            "-y",
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            inputURL.path,
            "-map",
            "0:v:0",
            "-map",
            "0:a?",
            "-c:v",
            "libx264",
            "-preset",
            "slow",
            "-crf",
            "18",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
            "-c:a",
            "copy",
            outputURL.path,
        ]
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = errorPipe

        AppLog.info(
            "Recording optimization ffmpeg execution: executable=\(executableURL.path); input=\(inputURL.path); output=\(outputURL.path); videoCodec=libx264; preset=slow; crf=18; pixelFormat=yuv420p; audioCodec=copy; command=\(formatCommand(executableURL: executableURL, arguments: arguments))"
        )

        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(decoding: stderrData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if process.terminationStatus == 0 {
                    AppLog.info(
                        "Recording optimization ffmpeg finished: status=0; output=\(outputURL.path)"
                    )
                    continuation.resume()
                } else if stderr.isEmpty {
                    continuation.resume(
                        throwing: RecordingOptimizerError.ffmpegFailed(
                            "ffmpeg exited with status \(process.terminationStatus)."
                        )
                    )
                } else {
                    continuation.resume(
                        throwing: RecordingOptimizerError.ffmpegFailed(stderr)
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

    private static func fileSize(of fileURL: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        let sizeBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard sizeBytes > 0 else {
            throw RecordingOptimizerError.emptyOutput(fileURL.lastPathComponent)
        }
        return sizeBytes
    }

    static func findFFmpegExecutable() -> URL? {
        let configuredPATH = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidateDirectories =
            [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/opt/local/bin",
            ] + configuredPATH.split(separator: ":").map(String.init)

        var seen = Set<String>()
        for directory in candidateDirectories where seen.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent("ffmpeg")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    private static func formatBytes(_ sizeBytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    private static func formatPercent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    static func formatCommand(
        executableURL: URL,
        arguments: [String]
    ) -> String {
        ([executableURL.path] + arguments)
            .map(shellQuoted)
            .joined(separator: " ")
    }

    private static func shellQuoted(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        let safeCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "/._-+:?=")
        )
        guard argument.unicodeScalars.allSatisfy(safeCharacters.contains) else {
            return "'\(argument.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
        }
        return argument
    }

    private static func logDecision(
        for fileURL: URL,
        originalSizeBytes: Int64,
        optimizedSizeBytes: Int64?,
        decision: String
    ) {
        let optimizedSizeDescription =
            optimizedSizeBytes.map(formatBytes)
            ?? "not produced"
        AppLog.info(
            "Recording optimization decision: file=\(fileURL.path); originalBytes=\(originalSizeBytes); originalSize=\(formatBytes(originalSizeBytes)); optimizedBytes=\(optimizedSizeBytes.map(String.init) ?? "not produced"); optimizedSize=\(optimizedSizeDescription); decision=\(decision)"
        )
    }
}

private enum RecordingOptimizerError: LocalizedError {
    case emptyOutput(String)
    case ffmpegFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyOutput(let filename):
            return "ffmpeg produced an empty optimized recording: \(filename)"
        case .ffmpegFailed(let message):
            return message
        }
    }
}
