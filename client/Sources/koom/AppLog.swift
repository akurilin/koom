import Foundation

enum AppLog {
    static func info(_ message: String) {
        write(level: "INFO", message: message)
    }

    static func infoToStandardOutput(_ message: String) {
        write(
            level: "INFO",
            message: message,
            handle: FileHandle.standardOutput
        )
    }

    static func error(_ message: String) {
        write(level: "ERROR", message: message)
    }

    private static func write(
        level: String,
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
        let line = "[\(timestamp)] [\(level)] \(message)\n"

        guard let data = line.data(using: .utf8) else { return }
        handle.write(data)
    }
}
