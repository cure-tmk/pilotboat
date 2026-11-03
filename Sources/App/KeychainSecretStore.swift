import Core
import Foundation
import Persistence
import Security

struct KeychainSecretStore: SecretStore {
    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            String(localized: "Keychain error: \(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")", bundle: .resources)
        }
    }

    private func query(host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: AppPaths.bundleID, kSecAttrAccount as String: host]
    }

    func token(host: String) throws -> String? {
        var q = query(host: host)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    func setToken(_ token: String, host: String) throws {
        let data = Data(token.utf8)
        var q = query(host: host)
        q[kSecValueData as String] = data
        var status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query(host: host) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func removeToken(host: String) throws {
        let status = SecItemDelete(query(host: host) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
