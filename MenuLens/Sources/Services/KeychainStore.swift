import Foundation
import Security

/// Tiny Keychain wrapper for our backend session token and the device
/// account's credentials. They never touch UserDefaults or the git repo.
///
/// Every item is `AfterFirstUnlockThisDeviceOnly` and not synchronizable: it
/// stays on this device (no iCloud Keychain, not in other devices' backups)
/// but survives deleting and reinstalling the app, so a reinstall finds the
/// same device account instead of opening a new one with new free credits.
enum KeychainStore {
    private static let service = "ai.xiangyang.MenuLens"
    private static let sessionAccount = "backend_session_token"
    /// The anonymous device account (POST /auth/anonymous): its id and the
    /// secret that renews its session.
    private static let deviceIDAccount = "device_account_id"
    private static let deviceSecretAccount = "device_account_secret"
    /// Where builds before the backend kept the user's own OpenAI key.
    private static let legacyAPIKeyAccount = "openai_api_key"

    static func loadSessionToken() -> String {
        load(account: sessionAccount)
    }

    static func saveSessionToken(_ token: String) {
        save(token, account: sessionAccount)
    }

    static func loadDeviceAccount() -> (id: String, secret: String)? {
        let id = load(account: deviceIDAccount), secret = load(account: deviceSecretAccount)
        return id.isEmpty || secret.isEmpty ? nil : (id, secret)
    }

    static func saveDeviceAccount(id: String, secret: String) {
        save(id, account: deviceIDAccount)
        save(secret, account: deviceSecretAccount)
    }

    #if DEBUG
    /// `-freshInstall`: forget the device account too (a Keychain item
    /// outlives uninstalling, so first launch needs an explicit way back).
    static func forgetDeviceAccount() {
        save("", account: deviceIDAccount)
        save("", account: deviceSecretAccount)
    }
    #endif

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
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        insert[kSecAttrSynchronizable as String] = false
        SecItemAdd(insert as CFDictionary, nil)
    }
}
