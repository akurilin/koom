import Foundation

protocol KoomPreferences: Sendable {
    func object(forKey key: String) -> Any?
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

final class UserDefaultsPreferences: KoomPreferences, @unchecked Sendable {
    private let defaults: UserDefaults

    init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }

    func object(forKey key: String) -> Any? {
        defaults.object(forKey: key)
    }

    func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func bool(forKey key: String) -> Bool {
        defaults.bool(forKey: key)
    }

    func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

final class InMemoryKoomPreferences: KoomPreferences, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func string(forKey key: String) -> String? {
        object(forKey: key) as? String
    }

    func bool(forKey key: String) -> Bool {
        if let value = object(forKey: key) as? Bool {
            return value
        }
        return (object(forKey: key) as? NSNumber)?.boolValue ?? false
    }

    func set(_ value: Any?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    func removeObject(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}

enum KoomRuntimeProfile {
    static let rootDirectoryURL: URL? = {
        guard
            let rawPath = ProcessInfo.processInfo.environment[
                "KOOM_CLIENT_PROFILE_DIR"
            ]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawPath.isEmpty
        else {
            return nil
        }

        let expandedPath = (rawPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath, isDirectory: true)
            .standardizedFileURL
    }()

    static let preferences: any KoomPreferences =
        if rootDirectoryURL == nil {
            UserDefaultsPreferences(.standard)
        } else {
            InMemoryKoomPreferences()
        }

    static var modelsDirectoryURL: URL? {
        rootDirectoryURL?.appendingPathComponent("models", isDirectory: true)
    }

    static var transcriptionModelsDirectoryURL: URL? {
        rootDirectoryURL?.appendingPathComponent(
            "transcription-models",
            isDirectory: true
        )
    }

    static var logsDirectoryURL: URL? {
        rootDirectoryURL?.appendingPathComponent("logs", isDirectory: true)
    }

    static var recordingsDirectoryURL: URL? {
        rootDirectoryURL?.appendingPathComponent(
            "recordings",
            isDirectory: true
        )
    }
}
