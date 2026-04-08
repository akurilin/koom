import Foundation
import Security

/// Thin wrapper around the Security framework's SecItem APIs for
/// storing generic password items.
///
/// koom uses this for one thing only: the admin secret that
/// authenticates the upload flow against the web backend. The secret
/// is a long-lived shared credential — long-lived enough that storing
/// it in `UserDefaults` would be a real security mistake, since
/// `~/Library/Preferences/` is unencrypted and accessible to
/// backup/sync tools.
///
/// `kSecAttrAccessibleAfterFirstUnlock` means the item becomes
/// readable once the user has unlocked their Mac after boot, which is
/// the right default for a user-interactive app (we don't need access
/// from a background daemon before login).
enum Keychain {
    enum KeychainError: LocalizedError {
        case saveFailed(OSStatus)
        case loadFailed(OSStatus)
        case deleteFailed(OSStatus)
        case corruptedData

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Could not save to Keychain (OSStatus \(status))."
            case .loadFailed(let status):
                return "Could not read from Keychain (OSStatus \(status))."
            case .deleteFailed(let status):
                return "Could not delete from Keychain (OSStatus \(status))."
            case .corruptedData:
                return "Keychain returned data that is not a UTF-8 string."
            }
        }
    }

    /// Insert or replace a string-valued secret under the given
    /// `service`/`account` pair. Existing items are deleted first so
    /// this is a straightforward "write" operation; callers never
    /// have to think about add-vs-update.
    static func save(service: String, account: String, value: String) throws {
        let data = Data(value.utf8)

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Ignore the status of the delete — if it wasn't there, fine.
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Read the stored secret. Returns `nil` if no item exists for
    /// the given `service`/`account` pair (which is a normal
    /// condition on first run), throws on any unexpected error.
    static func load(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.loadFailed(status)
        }
        guard let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            throw KeychainError.corruptedData
        }
        return value
    }

    /// Delete the secret if it exists. A missing item is not an
    /// error — this is intentionally idempotent.
    static func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}
