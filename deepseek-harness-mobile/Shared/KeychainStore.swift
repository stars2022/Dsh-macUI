import Foundation
import Security

enum KeychainStore {
    private static let service = "com.deepseek.harness.mobile"

    static func set(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var value = query
        value[kSecValueData as String] = data
        value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(value as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func get(account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    static func credential(profileID: UUID) throws -> RelayCredential? {
        guard let data = try get(account: "relay.\(profileID.uuidString)") else { return nil }
        return try JSONDecoder().decode(RelayCredential.self, from: data)
    }

    static func setCredential(_ value: RelayCredential, profileID: UUID) throws {
        try set(JSONEncoder().encode(value), account: "relay.\(profileID.uuidString)")
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)" }
}
