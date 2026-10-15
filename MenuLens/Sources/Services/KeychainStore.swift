import Foundation
import Security

/// Tiny Keychain wrapper for our backend session token. The token never
/// touches UserDefaults or the git repo.
enum KeychainStore {
    private static let service = "ai.xiangyang.MenuLens"
    private static let sessionAccount = "backend_session_token"
    /// Where builds before the backend kept the user's own OpenAI key.
    private static let legacyAPIKeyAccount = "openai_api_key"

    static func loadSessionToken() -> String {
        load(account: sessionAccount)
    }

    static func saveSessionToken(_ token: String) {
        save(token, account: sessionAccount)
    }

    /// The app no longer uses the user's OpenAI key, so a key left behind by
    /// an older build is deleted rather than kept around for nothing.
    static func removeLegacyAPIKey() {
        save("", account: legacyAPIKeyAccount)
    }

    private static func load(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return "" }
        return value
    }

    private static func save(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }
}
