import AppKit
import Foundation
import OSLog

enum AppLog {
    static let logsDirectoryURL = makeLogsDirectoryURL()
    static let currentLogURL = logsDirectoryURL.appendingPathComponent("koom.log")

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.koom.local"
    private static let logger = Logger(subsystem: subsystem, category: "app")
    private static let fileWriter = FileLogWriter(
        logsDirectoryURL: logsDirectoryURL,
        currentLogURL: currentLogURL
    )

    static func info(_ message: String) {
        write(level: .info, message: message)
    }

    static func infoToStandardOutput(_ message: String) {
        write(
            level: .info,
            message: message,
            handle: FileHandle.standardOutput
        )
    }

    static func error(_ message: String) {
        write(level: .error, message: message)
    }

    static func revealLogsInFinder() {
        fileWriter.ensurePrepared()
        if FileManager.default.fileExists(atPath: currentLogURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([currentLogURL])
        } else {
            NSWorkspace.shared.open(logsDirectoryURL)
        }
    }

    private static func write(
        level: LogLevel,
        message: String,
        handle: FileHandle = FileHandle.standardError
    ) {
        let timestamp = Date.now.ISO8601Format(
            .iso8601(
                timeZone: .current,
                dateSeparator: .dash,
                dateTimeSeparator: .space,
                timeSeparator: .colon
            )
        )
        let line = "[\(timestamp)] [\(level.rawValue)] \(message)\n"

        fileWriter.append(line)

        switch level {
        case .info:
            logger.info("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }

        guard let data = line.data(using: .utf8) else { return }
        handle.write(data)
    }

    private static func makeLogsDirectoryURL() -> URL {
        let libraryURL =
            FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return
            libraryURL
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("koom", isDirectory: true)
    }

    private enum LogLevel: String {
        case info = "INFO"
        case error = "ERROR"
    }
}

private final class FileLogWriter: @unchecked Sendable {
    private let logsDirectoryURL: URL
    private let currentLogURL: URL
    private let previousLogURL: URL
    private let queue = DispatchQueue(label: "com.koom.local.log-file-writer")
    private let maxLogSizeBytes: Int64 = 5 * 1024 * 1024

    init(logsDirectoryURL: URL, currentLogURL: URL) {
        self.logsDirectoryURL = logsDirectoryURL
        self.currentLogURL = currentLogURL
        self.previousLogURL = logsDirectoryURL.appendingPathComponent(
            "koom.previous.log"
        )
    }

    func ensurePrepared() {
        queue.sync {
            prepareLogDirectoryIfNeeded()
            createCurrentLogIfNeeded()
        }
    }

    func append(_ line: String) {
        queue.async {
            self.prepareLogDirectoryIfNeeded()
            self.createCurrentLogIfNeeded()
            self.rotateIfNeeded(forAdditionalBytes: line.utf8.count)
            self.writeLine(line)
        }
    }

    private func prepareLogDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(
                at: logsDirectoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            fputs("koom: could not create log directory at \(logsDirectoryURL.path): \(error.localizedDescription)\n", stderr)
        }
    }

    private func createCurrentLogIfNeeded() {
        if !FileManager.default.fileExists(atPath: currentLogURL.path) {
            FileManager.default.createFile(atPath: currentLogURL.path, contents: nil)
        }
    }

    private func rotateIfNeeded(forAdditionalBytes additionalBytes: Int) {
        let attributes =
            try? FileManager.default.attributesOfItem(
                atPath: currentLogURL.path
            )
        let currentSize =
            (attributes?[.size] as? NSNumber)?.int64Value
            ?? 0
        guard currentSize + Int64(additionalBytes) > maxLogSizeBytes else {
            return
        }

        do {
            if FileManager.default.fileExists(atPath: previousLogURL.path) {
                try FileManager.default.removeItem(at: previousLogURL)
            }
            if FileManager.default.fileExists(atPath: currentLogURL.path) {
                try FileManager.default.moveItem(
                    at: currentLogURL,
                    to: previousLogURL
                )
            }
            FileManager.default.createFile(atPath: currentLogURL.path, contents: nil)
        } catch {
            fputs("koom: could not rotate log files: \(error.localizedDescription)\n", stderr)
        }
    }

    private func writeLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }

        do {
            let handle = try FileHandle(forWritingTo: currentLogURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            fputs("koom: could not append to \(currentLogURL.path): \(error.localizedDescription)\n", stderr)
        }
    }
}
