import Foundation

/// User-supplied configuration that the desktop client needs to talk
/// to the koom web backend.
///
/// Two values, two storage mechanisms:
///
///   - `backendURL`        → `UserDefaults` (not a secret, just a URL)
///   - `deviceCredential`  → Keychain       (per-device bearer token +
///                                           the Google account that
///                                           minted it)
///
/// The device credential comes from signing in with Google in Settings
/// (see `DeviceSignIn`). The split exists because the Preferences
/// plist used by UserDefaults is plaintext on disk and readable by
/// anything with filesystem access to `~/Library/Preferences/`, which
/// is a bad place for a credential that authenticates every upload.
///
/// All accessors are `static` and synchronous — Keychain reads are
/// fast enough that there's no value in making them async, and the
/// simpler shape matches how the rest of the app is structured.
enum KoomConfig {
    /// A signed-in device: the bearer token the server minted for this
    /// Mac, and the Google account that approved it (for display).
    struct DeviceCredential: Codable, Equatable {
        var token: String
        var email: String
    }

    private struct StoredCredentials: Codable, Equatable {
        var dev: DeviceCredential?
        var prod: DeviceCredential?

        subscript(environment: KoomEnvironment) -> DeviceCredential? {
            get {
                switch environment {
                case .dev:
                    dev
                case .prod:
                    prod
                }
            }
            set {
                switch environment {
                case .dev:
                    dev = newValue
                case .prod:
                    prod = newValue
                }
            }
        }

        var isEmpty: Bool {
            dev == nil && prod == nil
        }
    }

    private enum ConfigError: LocalizedError {
        case corruptedCredentialsPayload

        var errorDescription: String? {
            switch self {
            case .corruptedCredentialsPayload:
                return "Stored sign-in credentials could not be decoded."
            }
        }
    }

    private static let activeEnvironmentKey = "com.koom.local.activeEnvironment"
    private static let legacyEnvironmentKey = "com.koom.local.legacyEnvironment"
    private static let legacyBackendURLKey = "com.koom.local.backendURL"

    /// Keychain generic password holding the JSON-encoded
    /// `StoredCredentials`. `service` is namespaced to the app's bundle
    /// identifier (`com.koom.local`); `account` is `"default"` because
    /// koom is single-user.
    private static let keychainService = "com.koom.local.deviceCredentials"
    private static let keychainAccount = "default"

    private static var preferences: any KoomPreferences {
        KoomRuntimeProfile.preferences
    }
    @MainActor private static var cachedCredentials = StoredCredentials()
    @MainActor private static var hasCachedCredentials = false

    /// Dev-mode escape hatch: when `KOOM_DEVICE_CREDENTIALS_FILE` is
    /// set, credentials live in that JSON file (the same payload stored
    /// in the Keychain item) and the Keychain is never touched, for
    /// reads or writes. Rebuilding re-signs the binary, which
    /// invalidates the Keychain item's ACL and triggers a password
    /// prompt on every run — unusable for agentic / unattended testing.
    /// The file is plaintext, so this is strictly for development
    /// machines.
    private static var credentialsFileOverride: URL? {
        ProcessInfo.processInfo.environment["KOOM_DEVICE_CREDENTIALS_FILE"]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }

    static var activeEnvironment: KoomEnvironment {
        get {
            if let raw = preferences.string(forKey: activeEnvironmentKey),
                let environment = KoomEnvironment(rawValue: raw)
            {
                return environment
            }
            return legacyEnvironment
        }
        set {
            preferences.set(newValue.rawValue, forKey: activeEnvironmentKey)
        }
    }

    static var legacyEnvironment: KoomEnvironment {
        if let raw = preferences.string(forKey: legacyEnvironmentKey),
            let environment = KoomEnvironment(rawValue: raw)
        {
            return environment
        }

        let inferred =
            KoomEnvironment.infer(
                from: loadURLString(from: legacyBackendURLKey).flatMap(URL.init)
            )
            ?? .prod
        preferences.set(inferred.rawValue, forKey: legacyEnvironmentKey)
        return inferred
    }

    // MARK: Backend URL

    static var backendURL: URL? {
        get { backendURL(for: activeEnvironment) }
        set { setBackendURL(newValue, for: activeEnvironment) }
    }

    static func backendURL(for environment: KoomEnvironment) -> URL? {
        if let url = loadURLString(from: backendURLKey(for: environment)).flatMap(URL.init) {
            return url
        }

        if environment == legacyEnvironment,
            let url = loadURLString(from: legacyBackendURLKey).flatMap(URL.init)
        {
            return url
        }

        return environment.defaultBackendURL
    }

    static func setBackendURL(
        _ newValue: URL?,
        for environment: KoomEnvironment
    ) {
        if let newValue {
            preferences.set(
                newValue.absoluteString,
                forKey: backendURLKey(for: environment)
            )
            if environment == legacyEnvironment {
                preferences.set(
                    newValue.absoluteString,
                    forKey: legacyBackendURLKey
                )
            }
        } else {
            preferences.removeObject(forKey: backendURLKey(for: environment))
            if environment == legacyEnvironment {
                preferences.removeObject(forKey: legacyBackendURLKey)
            }
        }
    }

    private static func loadURLString(from key: String) -> String? {
        guard let raw = preferences.string(forKey: key),
            !raw.isEmpty
        else {
            return nil
        }
        return raw
    }

    private static func backendURLKey(
        for environment: KoomEnvironment
    ) -> String {
        "com.koom.local.backendURL.\(environment.rawValue)"
    }

    // MARK: Device credential

    /// Returns the stored credential for the environment, or `nil` when
    /// that environment isn't signed in. Throws only on unexpected
    /// storage errors (not on "missing").
    @MainActor
    static func loadDeviceCredential(
        for environment: KoomEnvironment
    ) throws -> DeviceCredential? {
        try loadStoredCredentials()[environment]
    }

    @MainActor
    static func saveDeviceCredential(
        _ credential: DeviceCredential,
        for environment: KoomEnvironment
    ) throws {
        var credentials = try loadStoredCredentials()
        credentials[environment] = credential
        try persistStoredCredentials(credentials)
    }

    @MainActor
    static func clearDeviceCredential(
        for environment: KoomEnvironment
    ) throws {
        var credentials = try loadStoredCredentials()
        credentials[environment] = nil
        try persistStoredCredentials(credentials)
    }

    @MainActor
    private static func loadStoredCredentials() throws -> StoredCredentials {
        if hasCachedCredentials {
            return cachedCredentials
        }

        let credentials: StoredCredentials
        if let fileURL = credentialsFileOverride {
            AppLog.info(
                "Device credentials file override active: \(fileURL.path) (Keychain bypassed)."
            )
            credentials = try loadStoredCredentials(fromFile: fileURL)
        } else if let encoded = try Keychain.load(
            service: keychainService,
            account: keychainAccount
        ) {
            credentials = try decodeStoredCredentials(encoded)
        } else {
            credentials = StoredCredentials()
        }
        cachedCredentials = credentials
        hasCachedCredentials = true
        return credentials
    }

    private static func loadStoredCredentials(
        fromFile fileURL: URL
    ) throws -> StoredCredentials {
        // A missing file is the normal first-run state, same as a
        // missing Keychain item.
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return StoredCredentials()
        }
        return try decodeStoredCredentials(
            String(contentsOf: fileURL, encoding: .utf8)
        )
    }

    private static func decodeStoredCredentials(
        _ encoded: String
    ) throws -> StoredCredentials {
        do {
            return try JSONDecoder().decode(
                StoredCredentials.self,
                from: Data(encoded.utf8)
            )
        } catch {
            throw ConfigError.corruptedCredentialsPayload
        }
    }

    @MainActor
    private static func persistStoredCredentials(
        _ credentials: StoredCredentials
    ) throws {
        if let fileURL = credentialsFileOverride {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(credentials).write(
                to: fileURL,
                options: [.atomic]
            )
            // Plaintext credentials: keep them readable by the owner only.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } else if credentials.isEmpty {
            try Keychain.delete(service: keychainService, account: keychainAccount)
        } else {
            try Keychain.save(
                service: keychainService,
                account: keychainAccount,
                value: String(
                    decoding: JSONEncoder().encode(credentials),
                    as: UTF8.self
                )
            )
        }

        cachedCredentials = credentials
        hasCachedCredentials = true
    }

    // MARK: Convenience

    /// True if the environment has a backend URL and a signed-in
    /// device. Used for the first-run prompt and for gating the upload
    /// path. Silently returns `false` on any storage read error — those
    /// surface elsewhere with a proper error message.
    @MainActor
    static var isFullyConfigured: Bool {
        isFullyConfigured(for: activeEnvironment)
    }

    @MainActor
    static func isFullyConfigured(
        for environment: KoomEnvironment
    ) -> Bool {
        backendURL(for: environment) != nil
            && (try? loadDeviceCredential(for: environment)) != nil
    }
}
