import Foundation
import Security

enum KeychainError: LocalizedError {
    case itemNotFound
    case unexpectedData
    case authenticationFailed
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .itemNotFound: return "未找到钥匙串项目。"
        case .unexpectedData: return "钥匙串项目格式异常。"
        case .authenticationFailed: return "身份验证已取消或失败。"
        case .osStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "钥匙串错误（\(status)）：\(message)"
        }
    }
}

/// Immutable handle; Keychain Services serializes background access. No Data
/// Protection attributes, synchronizable items or shared access groups.
struct LoginKeychainStore: @unchecked Sendable {
    let service: String
    let keychain: SecKeychain

    nonisolated init(service: String, keychain: SecKeychain) {
        self.service = service
        self.keychain = keychain
    }

    nonisolated static func `default`(service: String) throws -> LoginKeychainStore {
        var keychain: SecKeychain?
        let status = SecKeychainCopyDefault(&keychain)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        guard let keychain else { throw KeychainError.unexpectedData }
        return LoginKeychainStore(service: service, keychain: keychain)
    }

    private nonisolated func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecMatchSearchList as String: [keychain]]
    }

    nonisolated func contains(account: String) throws -> Bool {
        var attributes = query(account: account)
        attributes[kSecReturnAttributes as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        attributes[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let status = SecItemCopyMatching(attributes as CFDictionary, nil)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound { return false }
        throw KeychainError.osStatus(status)
    }

    nonisolated func read(account: String) throws -> Data {
        var attributes = query(account: account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { throw KeychainError.itemNotFound }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        guard let data = result as? Data else { throw KeychainError.unexpectedData }
        return data
    }

    /// Add-only for encryption keys: a competing process must not overwrite an
    /// existing key after a not-found check.
    nonisolated func create(account: String, data: Data) throws {
        var access: SecAccess?
        // nil means ONLY the creating app, not an ACL that trusts every app.
        let accessStatus = SecAccessCreate("Glance 兼容版加密凭据" as CFString, nil, &access)
        guard accessStatus == errSecSuccess else { throw KeychainError.osStatus(accessStatus) }
        guard let access else { throw KeychainError.unexpectedData }
        var attributes = query(account: account)
        attributes.removeValue(forKey: kSecMatchSearchList as String)
        attributes[kSecUseKeychain as String] = keychain
        attributes[kSecAttrAccess as String] = access
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    nonisolated func save(account: String, data: Data) throws {
        let attributes = query(account: account)
        let changes = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(attributes as CFDictionary, changes)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.osStatus(status) }
        do {
            try create(account: account, data: data)
        } catch KeychainError.osStatus(let status) where status == errSecDuplicateItem {
            let retry = SecItemUpdate(attributes as CFDictionary, changes)
            guard retry == errSecSuccess else { throw KeychainError.osStatus(retry) }
        }
    }

    nonisolated func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }
}
