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
    private static let backendURLKey = "com.koom.local.backendURL"

    /// Service + account used for the Keychain generic password
    /// entry. `service` is namespaced to the app's bundle identifier
    /// (`com.koom.local`) so we don't collide with anything else on
    /// the user's system. `account` is `"default"` because koom is
    /// single-user — if we ever add multi-account support, this is
    /// where that distinction would live.
    private static let keychainService = "com.koom.local.adminSecret"
    private static let keychainAccount = "default"

    private static var defaults: UserDefaults { .standard }

    // MARK: Backend URL

    static var backendURL: URL? {
        get {
            guard let raw = defaults.string(forKey: backendURLKey),
                  !raw.isEmpty else {
                return nil
            }
            return URL(string: raw)
        }
        set {
            if let newValue {
                defaults.set(newValue.absoluteString, forKey: backendURLKey)
            } else {
                defaults.removeObject(forKey: backendURLKey)
            }
        }
    }

    // MARK: Admin secret

    /// Returns the stored admin secret, or `nil` if none is stored.
    /// Throws only on unexpected Keychain errors (not on "missing").
    static func loadAdminSecret() throws -> String? {
        try Keychain.load(service: keychainService, account: keychainAccount)
    }

    /// Overwrites any existing admin secret with the given value.
    /// Trims whitespace so pasting the secret with a trailing newline
    /// (easy to do from a shell) doesn't silently break auth.
    static func saveAdminSecret(_ secret: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        try Keychain.save(
            service: keychainService,
            account: keychainAccount,
            value: trimmed
        )
    }

    static func clearAdminSecret() throws {
        try Keychain.delete(
            service: keychainService,
            account: keychainAccount
        )
    }

    // MARK: Convenience

    /// True if both the backend URL and the admin secret are present.
    /// Used for the first-run prompt and for gating the upload path.
    /// Silently returns `false` on any Keychain read error — those
    /// surface elsewhere with a proper error message.
    static var isFullyConfigured: Bool {
        guard backendURL != nil else { return false }
        guard let secret = (try? loadAdminSecret()),
              !secret.isEmpty else {
            return false
        }
        return true
    }
}
