import Foundation
import Security

public enum KeychainHelper {
    private static let serviceName = "de.tobiha.ducko"

    private static func baseQuery(for jid: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: jid
        ]
    }

    public static func savePassword(_ password: String, for jid: String) {
        let data = Data(password.utf8)
        let query = baseQuery(for: jid)

        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        if existing == errSecSuccess {
            let update: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(query as CFDictionary, update as CFDictionary)
        } else {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public static func loadPassword(for jid: String) -> String? {
        var query = baseQuery(for: jid)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func deletePassword(for jid: String) {
        SecItemDelete(baseQuery(for: jid) as CFDictionary)
    }
}
