import Foundation

struct PreparedUploadSource: Sendable {
    let fileURL: URL
    let sizeBytes: Int64
    let cleanupDirectoryURL: URL?
    let usedOptimization: Bool
}

enum UploadOptimizer {
    private static let minimumSavingsRatio = 0.10

    static func prepareUploadSource(
        from originalFileURL: URL,
        originalSizeBytes: Int64,
        optimizeUploads: Bool,
        onOptimizationStarted: @Sendable () -> Void
    ) async -> PreparedUploadSource {
        guard optimizeUploads else {
            logDecision(
                for: originalFileURL,
                originalSizeBytes: originalSizeBytes,
                optimizedSizeBytes: nil,
                decision: "upload original file because upload optimization is disabled."
            )
            return PreparedUploadSource(
                fileURL: originalFileURL,
                sizeBytes: originalSizeBytes,
                cleanupDirectoryURL: nil,
                usedOptimization: false
            )
        }

        guard let ffmpegURL = findFFmpegExecutable() else {
            logDecision(
                for: originalFileURL,
                originalSizeBytes: originalSizeBytes,
                optimizedSizeBytes: nil,
                decision: "upload original file because ffmpeg was not found."
            )
            return PreparedUploadSource(
                fileURL: originalFileURL,
                sizeBytes: originalSizeBytes,
                cleanupDirectoryURL: nil,
                usedOptimization: false
            )
        }

        AppLog.infoToStandardOutput(
            "Upload optimization start for \(originalFileURL.lastPathComponent): original size \(formatBytes(originalSizeBytes))."
        )
        onOptimizationStarted()

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "koom-upload-\(UUID().uuidString)",
                isDirectory: true
            )
        let outputURL = tempDirectory.appendingPathComponent(
            originalFileURL.deletingPathExtension().lastPathComponent
                + "-upload.mp4"
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
                "Upload optimization failed for \(originalFileURL.lastPathComponent): \(error.localizedDescription)"
            )
            cleanupTemporaryDirectory(tempDirectory)
            return PreparedUploadSource(
                fileURL: originalFileURL,
                sizeBytes: originalSizeBytes,
                cleanupDirectoryURL: nil,
                usedOptimization: false
            )
        }

        let optimizedSizeBytes: Int64
        do {
            optimizedSizeBytes = try fileSize(of: outputURL)
        } catch {
            AppLog.error(
                "Upload optimization produced an unreadable output for \(originalFileURL.lastPathComponent): \(error.localizedDescription)"
            )
            cleanupTemporaryDirectory(tempDirectory)
            return PreparedUploadSource(
                fileURL: originalFileURL,
                sizeBytes: originalSizeBytes,
                cleanupDirectoryURL: nil,
                usedOptimization: false
            )
        }
        AppLog.infoToStandardOutput(
            "Upload optimization output for \(originalFileURL.lastPathComponent): optimized size \(formatBytes(optimizedSizeBytes))."
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
                    "upload original file because the optimized copy saved only \(formatPercent(savingsRatio)), below the 10% threshold."
            )
            cleanupTemporaryDirectory(tempDirectory)
            return PreparedUploadSource(
                fileURL: originalFileURL,
                sizeBytes: originalSizeBytes,
                cleanupDirectoryURL: nil,
                usedOptimization: false
            )
        }

        logDecision(
            for: originalFileURL,
            originalSizeBytes: originalSizeBytes,
            optimizedSizeBytes: optimizedSizeBytes,
            decision:
                "upload optimized copy because it saved \(formatPercent(savingsRatio)), meeting the 10% threshold."
        )
        return PreparedUploadSource(
            fileURL: outputURL,
            sizeBytes: optimizedSizeBytes,
            cleanupDirectoryURL: tempDirectory,
            usedOptimization: true
        )
    }

    static func cleanupTemporaryDirectory(_ directoryURL: URL?) {
        guard let directoryURL else { return }
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
        process.arguments = [
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
        process.standardOutput = Pipe()
        process.standardError = errorPipe

        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(decoding: stderrData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if process.terminationStatus == 0 {
                    continuation.resume()
                } else if stderr.isEmpty {
                    continuation.resume(
                        throwing: UploadOptimizerError.ffmpegFailed(
                            "ffmpeg exited with status \(process.terminationStatus)."
                        )
                    )
                } else {
                    continuation.resume(
                        throwing: UploadOptimizerError.ffmpegFailed(stderr)
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
            throw UploadOptimizerError.emptyOutput(fileURL.lastPathComponent)
        }
        return sizeBytes
    }

    private static func findFFmpegExecutable() -> URL? {
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

    private static func logDecision(
        for fileURL: URL,
        originalSizeBytes: Int64,
        optimizedSizeBytes: Int64?,
        decision: String
    ) {
        let optimizedSizeDescription =
            optimizedSizeBytes.map(formatBytes)
            ?? "not produced"
        AppLog.infoToStandardOutput(
            "Upload optimization decision for \(fileURL.lastPathComponent): original size \(formatBytes(originalSizeBytes)); optimized size \(optimizedSizeDescription); decision: \(decision)"
        )
    }
}

private enum UploadOptimizerError: LocalizedError {
    case emptyOutput(String)
    case ffmpegFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyOutput(let filename):
            return "ffmpeg produced an empty upload copy: \(filename)"
        case .ffmpegFailed(let message):
            return message
        }
    }
}
