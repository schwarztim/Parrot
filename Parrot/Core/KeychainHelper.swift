import Foundation
import Security

/// Thin wrapper around the macOS Keychain for storing and retrieving
/// sensitive strings (e.g. API keys) by service + account.
enum KeychainHelper {

    /// Saves a string value to the Keychain.
    /// Overwrites any existing value for the same service/account pair.
    @discardableResult
    static func save(_ value: String, service: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete any existing item first.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieves a string value, telling a missing item apart from a failed
    /// read. Returns nil only when no item exists; throws for anything else,
    /// such as a locked keychain over ssh (errSecInteractionNotAllowed) or an
    /// unreadable value.
    static func read(service: String, account: String) throws -> String? {
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
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw KeychainError.readFailed(status)
        }
        return value
    }

    /// Deletes a value from the Keychain.
    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}

/// A Keychain operation that did not succeed.
enum KeychainError: Error, Equatable {
    /// The item exists or may exist but could not be read (OSStatus).
    case readFailed(OSStatus)
    /// The item could not be saved.
    case writeFailed
}
