import Foundation
import Security

enum KeychainStore {
    @discardableResult
    static func save(_ value: String, service: String, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard let data = value.data(using: .utf8), !value.isEmpty else {
            let deleteStatus = SecItemDelete(query as CFDictionary)
            return deleteStatus == errSecItemNotFound ? errSecSuccess : deleteStatus
        }
        let protectedAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, protectedAttributes as CFDictionary)
        guard updateStatus == errSecItemNotFound else { return updateStatus }

        var addAttributes = query
        protectedAttributes.forEach { addAttributes[$0.key] = $0.value }
        return SecItemAdd(addAttributes as CFDictionary, nil)
    }

    static func load(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
