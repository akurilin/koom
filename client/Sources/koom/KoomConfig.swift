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
    private static let activeEnvironmentKey = "com.koom.local.activeEnvironment"
    private static let legacyEnvironmentKey = "com.koom.local.legacyEnvironment"
    private static let legacyBackendURLKey = "com.koom.local.backendURL"

    /// Service + account used for the Keychain generic password
    /// entry. `service` is namespaced to the app's bundle identifier
    /// (`com.koom.local`) so we don't collide with anything else on
    /// the user's system. `account` is `"default"` because koom is
    /// single-user — if we ever add multi-account support, this is
    /// where that distinction would live.
    private static let legacyKeychainService = "com.koom.local.adminSecret"
    private static let keychainAccount = "default"

    private static var defaults: UserDefaults { .standard }

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
    static func loadAdminSecret() throws -> String? {
        try loadAdminSecret(for: activeEnvironment)
    }

    static func loadAdminSecret(
        for environment: KoomEnvironment
    ) throws -> String? {
        if let secret = try Keychain.load(
            service: keychainService(for: environment),
            account: keychainAccount
        ) {
            return secret
        }

        if environment == legacyEnvironment {
            return try Keychain.load(
                service: legacyKeychainService,
                account: keychainAccount
            )
        }

        return nil
    }

    /// Overwrites any existing admin secret with the given value.
    /// Trims whitespace so pasting the secret with a trailing newline
    /// (easy to do from a shell) doesn't silently break auth.
    static func saveAdminSecret(_ secret: String) throws {
        try saveAdminSecret(secret, for: activeEnvironment)
    }

    static func saveAdminSecret(
        _ secret: String,
        for environment: KoomEnvironment
    ) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        try Keychain.save(
            service: keychainService(for: environment),
            account: keychainAccount,
            value: trimmed
        )
        if environment == legacyEnvironment {
            try Keychain.save(
                service: legacyKeychainService,
                account: keychainAccount,
                value: trimmed
            )
        }
    }

    static func clearAdminSecret() throws {
        try clearAdminSecret(for: activeEnvironment)
    }

    static func clearAdminSecret(
        for environment: KoomEnvironment
    ) throws {
        try Keychain.delete(
            service: keychainService(for: environment),
            account: keychainAccount
        )
        if environment == legacyEnvironment {
            try Keychain.delete(
                service: legacyKeychainService,
                account: keychainAccount
            )
        }
    }

    private static func keychainService(
        for environment: KoomEnvironment
    ) -> String {
        "com.koom.local.adminSecret.\(environment.rawValue)"
    }

    // MARK: Convenience

    /// True if both the backend URL and the admin secret are present.
    /// Used for the first-run prompt and for gating the upload path.
    /// Silently returns `false` on any Keychain read error — those
    /// surface elsewhere with a proper error message.
    static var isFullyConfigured: Bool {
        isFullyConfigured(for: activeEnvironment)
    }

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
