import Foundation
import Security

/// Login-keychain generic-password lookup. Mirrors the CLI's
/// `KeychainSecretStore` (service `apple-tasks`) but never throws — the
/// server binary cannot import the CLI module.
public enum KeychainSecret {
    public static func read(account: String, service: String = "apple-tasks") -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty
        else { return nil }
        return value
    }
}
