import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.spotifydisplay.tokens"

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Update-in-place first, add only if missing. The old version deleted first and ignored
    /// `SecItemAdd`'s status, so a failed add lost the (rotated) refresh token with no signal and
    /// the user was silently signed out on the next launch. Returns the final status.
    @discardableResult
    static func save(_ value: String, account: String) -> OSStatus {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attrs) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            NSLog("Keychain save(%@) failed: OSStatus %d", account, status)
        }
        return status
    }

    static func load(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status != errSecSuccess && status != errSecItemNotFound {
            // e.g. errSecInteractionNotAllowed while the device is locked: not the same as "no item".
            NSLog("Keychain load(%@) failed: OSStatus %d", account, status)
        }
        guard status == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// Returns `errSecSuccess` when the item is gone afterwards (including "there was none").
    @discardableResult
    static func delete(account: String) -> OSStatus {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status == errSecItemNotFound { return errSecSuccess }
        if status != errSecSuccess {
            NSLog("Keychain delete(%@) failed: OSStatus %d", account, status)
        }
        return status
    }
}
