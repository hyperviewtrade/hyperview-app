import Foundation
import Security

// MARK: - SessionKeyManager
// Stores a session signature in the Keychain (NOT UserDefaults).
// After the user signs once, orders can be submitted without re-signing.
// Session expires after 30 minutes for security.

@MainActor
final class SessionKeyManager {
    static let shared = SessionKeyManager()

    private let signatureKeychainId = "com.hyperview.session.signature"
    private let addressKeychainId   = "com.hyperview.session.address"
    private let createdAtKey        = "hl_session_created" // Date only — OK in UserDefaults

    /// Session TTL — 30 minutes
    private let sessionTTL: TimeInterval = 1800

    private init() {
        // Migrate any old UserDefaults session to Keychain on first run
        migrateFromUserDefaults()
    }

    // MARK: - Store

    func storeSessionSignature(_ signature: String, for address: String) {
        setKeychainItem(signature, key: signatureKeychainId)
        setKeychainItem(address, key: addressKeychainId)
        UserDefaults.standard.set(Date(), forKey: createdAtKey)
    }

    func storeSessionSignature(_ signature: String) {
        let address = WalletManager.shared.connectedWallet?.address ?? ""
        storeSessionSignature(signature, for: address)
    }

    // MARK: - Read

    var sessionSignature: String? {
        guard !isExpired else {
            clearSessionKey()
            return nil
        }
        return getKeychainItem(key: signatureKeychainId)
    }

    var sessionAddress: String? {
        getKeychainItem(key: addressKeychainId)
    }

    var sessionCreatedAt: Date? {
        UserDefaults.standard.object(forKey: createdAtKey) as? Date
    }

    /// Valid if signature exists, belongs to current wallet, and not expired
    var hasActiveSession: Bool {
        guard let sig = sessionSignature, !sig.isEmpty else { return false }
        guard let addr = sessionAddress else { return false }
        guard !isExpired else { return false }
        return addr == (WalletManager.shared.connectedWallet?.address ?? "")
    }

    private var isExpired: Bool {
        guard let created = sessionCreatedAt else { return true }
        return Date().timeIntervalSince(created) > sessionTTL
    }

    // MARK: - Clear

    func clearSessionKey() {
        deleteKeychainItem(key: signatureKeychainId)
        deleteKeychainItem(key: addressKeychainId)
        UserDefaults.standard.removeObject(forKey: createdAtKey)
    }

    // MARK: - Keychain Helpers

    private func setKeychainItem(_ value: String, key: String) {
        let data = Data(value.utf8)

        // Delete existing
        deleteKeychainItem(key: key)

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String:   data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("[SessionKey] Keychain write failed: \(status)")
        }
    }

    private func getKeychainItem(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteKeychainItem(key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Migration from UserDefaults (one-time)

    private func migrateFromUserDefaults() {
        let oldSigKey = "hl_session_signature"
        let oldAddrKey = "hl_session_address"

        if let oldSig = UserDefaults.standard.string(forKey: oldSigKey),
           !oldSig.isEmpty {
            let oldAddr = UserDefaults.standard.string(forKey: oldAddrKey) ?? ""
            setKeychainItem(oldSig, key: signatureKeychainId)
            setKeychainItem(oldAddr, key: addressKeychainId)
            // Remove from UserDefaults
            UserDefaults.standard.removeObject(forKey: oldSigKey)
            UserDefaults.standard.removeObject(forKey: oldAddrKey)
            print("[SessionKey] Migrated session from UserDefaults to Keychain")
        }
    }
}
