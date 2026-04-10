import Foundation

/// User-supplied configuration that the desktop client needs to talk
/// to the koom web backend.
///
/// Two values, two storage mechanisms:
///
///   - `backendURL`      → `UserDefaults` (not a secret, just a URL)
///   - `adminSecret`     → Keychain       (long-lived shared credential)
///
/// The split exists because the Preferences plist used by
/// UserDefaults is plaintext on disk and readable by anything with
/// filesystem access to `~/Library/Preferences/`, which is a bad
/// place for a credential that authenticates every upload.
///
/// All accessors are `static` and synchronous — Keychain reads are
/// fast enough that there's no value in making them async, and the
/// simpler shape matches how the rest of the app is structured.
enum KoomConfig {
    struct AdminSecrets: Equatable {
        var dev: String
        var prod: String
    }

    private struct StoredAdminSecrets: Codable, Equatable {
        var dev: String?
        var prod: String?

        subscript(environment: KoomEnvironment) -> String? {
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

        var normalized: StoredAdminSecrets {
            StoredAdminSecrets(
                dev: Self.normalize(dev),
                prod: Self.normalize(prod)
            )
        }

        var isEmpty: Bool {
            dev == nil && prod == nil
        }

        func exposedValues() -> AdminSecrets {
            AdminSecrets(
                dev: dev ?? "",
                prod: prod ?? ""
            )
        }

        private static func normalize(_ secret: String?) -> String? {
            guard let secret else { return nil }
            let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private enum ConfigError: LocalizedError {
        case corruptedAdminSecretsPayload

        var errorDescription: String? {
            switch self {
            case .corruptedAdminSecretsPayload:
                return "Stored admin secrets could not be decoded from Keychain."
            }
        }
    }

    private static let activeEnvironmentKey = "com.koom.local.activeEnvironment"
    private static let legacyEnvironmentKey = "com.koom.local.legacyEnvironment"
    private static let legacyBackendURLKey = "com.koom.local.backendURL"

    /// Service + account used for the Keychain generic password
    /// entry. `service` is namespaced to the app's bundle identifier
    /// (`com.koom.local`) so we don't collide with anything else on
    /// the user's system. `account` is `"default"` because koom is
    /// single-user — if we ever add multi-account support, this is
    /// where that distinction would live.
    private static let bundledKeychainService = "com.koom.local.adminSecrets"
    private static let legacyKeychainService = "com.koom.local.adminSecret"
    private static let keychainAccount = "default"

    private static var defaults: UserDefaults { .standard }
    @MainActor private static var cachedAdminSecrets = StoredAdminSecrets()
    @MainActor private static var hasCachedAdminSecrets = false

    static var activeEnvironment: KoomEnvironment {
        get {
            if let raw = defaults.string(forKey: activeEnvironmentKey),
                let environment = KoomEnvironment(rawValue: raw)
            {
                return environment
            }
            return legacyEnvironment
        }
        set {
            defaults.set(newValue.rawValue, forKey: activeEnvironmentKey)
        }
    }

    static var legacyEnvironment: KoomEnvironment {
        if let raw = defaults.string(forKey: legacyEnvironmentKey),
            let environment = KoomEnvironment(rawValue: raw)
        {
            return environment
        }

        let inferred =
            KoomEnvironment.infer(
                from: loadURLString(from: legacyBackendURLKey).flatMap(URL.init)
            )
            ?? .prod
        defaults.set(inferred.rawValue, forKey: legacyEnvironmentKey)
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
            defaults.set(
                newValue.absoluteString,
                forKey: backendURLKey(for: environment)
            )
            if environment == legacyEnvironment {
                defaults.set(newValue.absoluteString, forKey: legacyBackendURLKey)
            }
        } else {
            defaults.removeObject(forKey: backendURLKey(for: environment))
            if environment == legacyEnvironment {
                defaults.removeObject(forKey: legacyBackendURLKey)
            }
        }
    }

    private static func loadURLString(from key: String) -> String? {
        guard let raw = defaults.string(forKey: key),
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

    // MARK: Admin secret

    /// Returns the stored admin secret, or `nil` if none is stored.
    /// Throws only on unexpected Keychain errors (not on "missing").
    @MainActor
    static func loadAdminSecret() throws -> String? {
        try loadAdminSecret(for: activeEnvironment)
    }

    @MainActor
    static func loadAdminSecret(
        for environment: KoomEnvironment
    ) throws -> String? {
        let secrets = try loadStoredAdminSecrets()
        return secrets[environment]
    }

    @MainActor
    static func loadAdminSecrets() throws -> AdminSecrets {
        try loadStoredAdminSecrets().exposedValues()
    }

    /// Overwrites any existing admin secret with the given value.
    /// Trims whitespace so pasting the secret with a trailing newline
    /// (easy to do from a shell) doesn't silently break auth.
    @MainActor
    static func saveAdminSecret(_ secret: String) throws {
        try saveAdminSecret(secret, for: activeEnvironment)
    }

    @MainActor
    static func saveAdminSecret(
        _ secret: String,
        for environment: KoomEnvironment
    ) throws {
        var secrets = try loadStoredAdminSecrets()
        secrets[environment] = secret
        try persistStoredAdminSecrets(secrets)
    }

    @MainActor
    static func clearAdminSecret() throws {
        try clearAdminSecret(for: activeEnvironment)
    }

    @MainActor
    static func clearAdminSecret(
        for environment: KoomEnvironment
    ) throws {
        var secrets = try loadStoredAdminSecrets()
        secrets[environment] = nil
        try persistStoredAdminSecrets(secrets)
    }

    private static func keychainService(
        for environment: KoomEnvironment
    ) -> String {
        "com.koom.local.adminSecret.\(environment.rawValue)"
    }

    @MainActor
    private static func loadStoredAdminSecrets() throws -> StoredAdminSecrets {
        if hasCachedAdminSecrets {
            return cachedAdminSecrets
        }

        let secrets = try loadStoredAdminSecretsFromKeychain()
        cachedAdminSecrets = secrets
        hasCachedAdminSecrets = true
        return secrets
    }

    @MainActor
    private static func loadStoredAdminSecretsFromKeychain() throws -> StoredAdminSecrets {
        if let encodedSecrets = try Keychain.load(
            service: bundledKeychainService,
            account: keychainAccount
        ) {
            return try decodeStoredAdminSecrets(encodedSecrets)
        }

        let legacySecrets = try loadLegacyStoredAdminSecrets()

        if !legacySecrets.isEmpty {
            try persistStoredAdminSecrets(
                legacySecrets,
                removeLegacyItems: true
            )
        }

        return legacySecrets
    }

    private static func decodeStoredAdminSecrets(
        _ encodedSecrets: String
    ) throws -> StoredAdminSecrets {
        let data = Data(encodedSecrets.utf8)

        do {
            return try JSONDecoder().decode(
                StoredAdminSecrets.self,
                from: data
            ).normalized
        } catch {
            throw ConfigError.corruptedAdminSecretsPayload
        }
    }

    private static func loadLegacyStoredAdminSecrets() throws -> StoredAdminSecrets {
        var secrets = StoredAdminSecrets()

        secrets[.dev] = try Keychain.load(
            service: keychainService(for: .dev),
            account: keychainAccount
        )
        secrets[.prod] = try Keychain.load(
            service: keychainService(for: .prod),
            account: keychainAccount
        )

        if secrets[legacyEnvironment] == nil {
            secrets[legacyEnvironment] = try Keychain.load(
                service: legacyKeychainService,
                account: keychainAccount
            )
        }

        return secrets.normalized
    }

    @MainActor
    private static func persistStoredAdminSecrets(
        _ secrets: StoredAdminSecrets,
        removeLegacyItems: Bool = true
    ) throws {
        let normalizedSecrets = secrets.normalized

        if normalizedSecrets.isEmpty {
            try Keychain.delete(
                service: bundledKeychainService,
                account: keychainAccount
            )
        } else {
            let encodedSecrets = try String(
                decoding: JSONEncoder().encode(normalizedSecrets),
                as: UTF8.self
            )
            try Keychain.save(
                service: bundledKeychainService,
                account: keychainAccount,
                value: encodedSecrets
            )
        }

        if removeLegacyItems {
            try deleteLegacyAdminSecretItems()
        }

        cachedAdminSecrets = normalizedSecrets
        hasCachedAdminSecrets = true
    }

    private static func deleteLegacyAdminSecretItems() throws {
        try Keychain.delete(
            service: keychainService(for: .dev),
            account: keychainAccount
        )
        try Keychain.delete(
            service: keychainService(for: .prod),
            account: keychainAccount
        )
        try Keychain.delete(
            service: legacyKeychainService,
            account: keychainAccount
        )
    }

    // MARK: Convenience

    /// True if both the backend URL and the admin secret are present.
    /// Used for the first-run prompt and for gating the upload path.
    /// Silently returns `false` on any Keychain read error — those
    /// surface elsewhere with a proper error message.
    @MainActor
    static var isFullyConfigured: Bool {
        isFullyConfigured(for: activeEnvironment)
    }

    @MainActor
    static func isFullyConfigured(
        for environment: KoomEnvironment
    ) -> Bool {
        guard backendURL(for: environment) != nil else { return false }
        guard let secret = (try? loadAdminSecret(for: environment)),
            !secret.isEmpty
        else {
            return false
        }
        return true
    }
}
