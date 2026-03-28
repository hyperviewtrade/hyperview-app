import Foundation
import Combine
import UIKit
import CryptoKit
import LocalAuthentication
import CommonCrypto
import WidgetKit
import libsecp256k1

// MARK: - Wallet types

enum WalletApp: String, CaseIterable, Identifiable {
    case metamask  = "MetaMask"
    case rabby     = "Rabby"
    case zerion    = "Zerion"
    case walletConnect = "WalletConnect"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .metamask:      return "🦊"
        case .rabby:         return "🐰"
        case .zerion:        return "⚡️"
        case .walletConnect: return "🔗"
        }
    }

    var scheme: String? {
        switch self {
        case .metamask:  return "metamask://"
        case .rabby:     return "rabby://"
        case .zerion:    return "zerion://"
        case .walletConnect: return nil
        }
    }

    var isInstalled: Bool {
        guard let scheme, let url = URL(string: scheme) else { return false }
        return UIApplication.shared.canOpenURL(url)
    }
}

// MARK: - Connected wallet

struct ConnectedWallet: Codable {
    let address:   String
    let walletApp: String
    let connectedAt: Date

    var shortAddress: String {
        guard address.count > 10 else { return address }
        return "\(address.prefix(6))...\(address.suffix(4))"
    }
}

// MARK: - WalletManager

@MainActor
final class WalletManager: ObservableObject {
    static let shared = WalletManager()

    @Published private(set) var connectedWallet: ConnectedWallet? {
        didSet { _isLocalWalletCached = nil }   // invalidate cache on wallet change
    }
    @Published private(set) var isConnecting = false
    @Published var errorMessage: String?

    // Account balances / state (refreshed after connect)
    @Published var perpValue: Double = UserDefaults.standard.double(forKey: "cached_perpValue")
    @Published var spotValue: Double = UserDefaults.standard.double(forKey: "cached_spotValue")
    @Published var perpWithdrawable: Double = 0  // Available margin for perp trading
    @Published var spotTokenBalances: [String: Double] = [:]  // Per-token spot holdings (coin → total amount)
    @Published var spotTokenAvailable: [String: Double] = [:]  // Per-token AVAILABLE spot (total - hold)
    @Published var spotTokenEntryNtl: [String: Double] = [:]   // Per-token entry notional (USD cost basis)
    @Published var activePositions: [PerpPosition] = []       // Live perp positions (main + HIP-3)
    @Published var isPortfolioMargin: Bool = false              // Account abstraction mode
    @Published var activeVaultAddress: String? = nil            // Sub-account address (nil = master)
    var mainDexPositions: [PerpPosition] = []                 // Main DEX positions (from WebSocket)
    var hip3Positions: [PerpPosition] = []                    // HIP-3 positions (polled periodically)
    private var hip3PollTimer: Timer?
    @Published var dailyPnl: Double = 0
    @Published var evmHypeBalance: Double = 0  // HYPE on HyperEVM (needs transfer to Core)
    @Published var stakingTier: StakingTier = .none

    /// Per-address balance cache. Values persist across account switches so
    /// revisiting an account shows its last known balance instantly.
    var accountValueCache: [String: Double] = [:]

    /// accountValue — reads from the per-address cache for the current address.
    /// Stored as @Published so SwiftUI views update when it changes.
    @Published var accountValue: Double = UserDefaults.standard.double(forKey: "cached_accountValue")

    /// Write accountValue for a specific address into the per-address cache,
    /// and update the @Published accountValue if this is the active address.
    private func setAccountValue(_ value: Double, for address: String) {
        let key = address.lowercased()
        accountValueCache[key] = value
        print("[CACHE-WRITE] addr=\(key.prefix(10))… value=\(value)")
        // Update @Published if this write is for the currently active address
        if let current = connectedWallet?.address.lowercased(), current == key {
            accountValue = value
            print("[CACHE-READ] addr=\(current.prefix(10))… accountValue=\(value)")
        }
    }

    /// Sync @Published accountValue from the per-address cache for the current wallet.
    /// Call this after switching connectedWallet so UI shows the cached value instantly.
    private func syncAccountValueFromCache() {
        guard let addr = connectedWallet?.address.lowercased() else {
            // No wallet connected — don't reset to 0 (keep last value for animation)
            return
        }
        let cached = accountValueCache[addr] ?? 0
        accountValue = cached
        print("[CACHE-SYNC] addr=\(addr.prefix(10))… cached=\(cached)")
    }

    /// Cached sub-account API response for instant display in Settings.
    /// Key: master address, Value: raw JSON array from subAccounts API.
    private(set) var cachedSubAccountsJSON: [[String: Any]] = []
    /// The master wallet address (the address saved to UserDefaults, never changes on sub-account switch).
    /// Use this to always get the real master address even when connectedWallet is a sub-account.
    var savedMasterAddress: String? {
        guard let data = UserDefaults.standard.data(forKey: walletKey),
              let wallet = try? JSONDecoder().decode(ConnectedWallet.self, from: data)
        else { return nil }
        return wallet.address
    }
    private var cachedSubAccountsMaster: String?
    private var portfolioMarginByAddress: [String: Bool] = [:]

    func getCachedSubAccounts(for master: String) -> [[String: Any]]? {
        guard master == cachedSubAccountsMaster, !cachedSubAccountsJSON.isEmpty else { return nil }
        return cachedSubAccountsJSON
    }

    func cacheSubAccounts(_ data: [[String: Any]], for master: String) {
        cachedSubAccountsJSON = data
        cachedSubAccountsMaster = master
    }

    // Biometric (Face ID / Touch ID) for transaction signing & app lock
    @Published var biometricEnabled: Bool {
        didSet { UserDefaults.standard.set(biometricEnabled, forKey: biometricKey) }
    }

    /// App lock state — false until user authenticates with Face ID / PIN
    @Published var isUnlocked: Bool = false

    /// Timestamp when app entered background — used for grace period
    private var backgroundTimestamp: Date?
    /// Grace period: skip Face ID if app was backgrounded less than this duration
    private let lockGracePeriod: TimeInterval = 5
    /// Prevents concurrent authenticateAppLaunch() calls from interfering
    private var isAuthenticating = false

    /// True if this is a wallet we generated in-app (has private key in Keychain)
    /// AND the key actually matches the connected wallet address.
    ///
    /// Cached to avoid per-render Keychain I/O + secp256k1 + Keccak256.
    /// Invalidated automatically when `connectedWallet` changes (via didSet).
    private var _isLocalWalletCached: Bool?
    var isLocalWallet: Bool {
        if let cached = _isLocalWalletCached { return cached }
        let result = computeIsLocalWallet()
        _isLocalWalletCached = result
        return result
    }

    private func computeIsLocalWallet() -> Bool {
        guard connectedWallet?.walletApp == "Local",
              let keyData = loadPrivateKey() else { return false }
        guard let derivedAddress = Self.deriveAddress(from: keyData) else { return false }
        let matches = derivedAddress.lowercased() == connectedWallet?.address.lowercased()
        if !matches {
            // Log once per wallet change, not per render
            print("⚠️ isLocalWallet: key address \(derivedAddress) ≠ wallet address \(connectedWallet?.address ?? "nil")")
        }
        return matches
    }

    /// Derives an Ethereum address from a 32-byte private key.
    static func deriveAddress(from keyData: Data) -> String? {
        let keyBytes = [UInt8](keyData)
        guard keyBytes.count == 32 else { return nil }
        guard let ctx = secp256k1_context_create(UInt32(1)) else { return nil }
        defer { secp256k1_context_destroy(ctx) }

        var pubkey = secp256k1_pubkey()
        guard secp256k1_ec_pubkey_create(ctx, &pubkey, keyBytes) == 1 else { return nil }

        var serialized = [UInt8](repeating: 0, count: 65)
        var outputLen: Int = 65
        guard secp256k1_ec_pubkey_serialize(ctx, &serialized, &outputLen, &pubkey, UInt32(2)) == 1 else { return nil }

        let pubKeyNoPrefix = Data(serialized[1..<65])
        let hash = Keccak256.hash(data: pubKeyNoPrefix)
        let addressBytes = hash.suffix(20)
        return "0x" + addressBytes.map { String(format: "%02x", $0) }.joined()
    }

    enum StakingTier: String {
        case none    = "0 HYPE"
        case tier1   = "10 HYPE"        // 10+ HYPE staked   → 5%
        case tier2   = "100 HYPE"       // 100+ HYPE staked  → 10%
        case tier3   = "1,000 HYPE"     // 1,000+ HYPE       → 15%
        case tier4   = "10,000 HYPE"    // 10,000+ HYPE      → 20%
        case tier5   = "100,000 HYPE"   // 100,000+ HYPE     → 30%
        case tier6   = "500,000 HYPE"   // 500,000+ HYPE     → 40%

        var feeDiscount: Double {
            switch self {
            case .none:  return 0
            case .tier1: return 0.05
            case .tier2: return 0.10
            case .tier3: return 0.15
            case .tier4: return 0.20
            case .tier5: return 0.30
            case .tier6: return 0.40
            }
        }
    }

    /// True once the user has dismissed the first-launch onboarding popup
    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: onboardingKey) }
    }

    private let walletKey    = "hl_connected_wallet"
    private let biometricKey = "hl_biometric_enabled"
    private let onboardingKey = "hl_onboarding_completed"
    private let pkKeychainId = "com.hyperview.wallet.privatekey"
    private let pkOriginalKeychainId = "com.hyperview.wallet.privatekey.original" // TEMPORARY
    private let passwordKeychainId = "com.hyperview.wallet.password"

    /// Whether the user has set an app password
    var hasPassword: Bool { loadPasswordHash() != nil }

    private init() {
        biometricEnabled = UserDefaults.standard.bool(forKey: biometricKey)
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: onboardingKey)
        loadSavedWallet()
        // If UserDefaults was cleared but Keychain still has the private key,
        // recover the wallet address from it (prevents fund loss).
        if connectedWallet == nil {
            if let existingKey = loadPrivateKey() {
                recoverWalletFromKey(existingKey)
            } else {
                generateLocalWallet()
            }
        }
        // Safety: verify key matches connected wallet address
        verifyKeyAddressConsistency()
    }

    /// Detects and fixes mismatch between Keychain private key and connected wallet address.
    private func verifyKeyAddressConsistency() {
        guard let wallet = connectedWallet else {
            print("🔑 [VERIFY] No connected wallet")
            return
        }
        guard let keyData = loadPrivateKey() else {
            print("🔑 [VERIFY] No private key in Keychain (walletApp=\(wallet.walletApp))")
            return
        }
        guard let derivedAddress = Self.deriveAddress(from: keyData) else {
            print("🔑 [VERIFY] Failed to derive address from key")
            return
        }

        print("🔑 [VERIFY] walletApp=\(wallet.walletApp) wallet=\(wallet.address) key=\(derivedAddress)")

        if derivedAddress.lowercased() != wallet.address.lowercased() {
            print("🚨 KEY MISMATCH: key→\(derivedAddress) wallet→\(wallet.address) walletApp=\(wallet.walletApp)")
            print("🚨 WARNING: Private key does NOT match connected wallet address!")
            print("🚨 The key in Keychain is for \(derivedAddress), but funds are on \(wallet.address)")
            // Do NOT auto-change address — user has funds on the current address
        } else {
            print("✅ Key/address consistent: \(derivedAddress) (walletApp=\(wallet.walletApp))")
            // Fix walletApp if it's not "Local" but we have a matching key
            if wallet.walletApp != "Local" {
                print("🔧 Fixing walletApp: \(wallet.walletApp) → Local")
                let fixed = ConnectedWallet(address: wallet.address, walletApp: "Local", connectedAt: wallet.connectedAt)
                connectedWallet = fixed
                if let data = try? JSONEncoder().encode(fixed) {
                    UserDefaults.standard.set(data, forKey: walletKey)
                }
            }
        }
    }

    /// Returns the private key as a hex string (for onboarding display)
    var privateKeyHex: String? {
        guard let data = loadPrivateKey() else { return nil }
        return "0x" + data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Wallet recovery (Keychain still has key but UserDefaults was cleared)

    /// Re-derives the Ethereum address from an existing private key in Keychain.
    /// Prevents fund loss if UserDefaults is cleared (app reset, migration, etc.).
    private func recoverWalletFromKey(_ keyData: Data) {
        let keyBytes = [UInt8](keyData)
        guard keyBytes.count == 32 else {
            print("⚠️ Invalid key length in Keychain, generating new wallet")
            generateLocalWallet()
            return
        }

        guard let ctx = secp256k1_context_create(UInt32(1)) else {
            print("❌ recoverWallet: secp256k1_context_create returned nil")
            return
        }
        defer { secp256k1_context_destroy(ctx) }

        var pubkey = secp256k1_pubkey()
        guard secp256k1_ec_pubkey_create(ctx, &pubkey, keyBytes) == 1 else {
            print("❌ recoverWallet: secp256k1_ec_pubkey_create failed")
            return
        }

        var serialized = [UInt8](repeating: 0, count: 65)
        var outputLen: Int = 65
        guard secp256k1_ec_pubkey_serialize(ctx, &serialized, &outputLen, &pubkey, UInt32(2)) == 1 else {
            print("❌ recoverWallet: secp256k1_ec_pubkey_serialize failed")
            return
        }

        let pubKeyNoPrefix = Data(serialized[1..<65])
        let hash = Keccak256.hash(data: pubKeyNoPrefix)
        let addressBytes = hash.suffix(20)
        let address = "0x" + addressBytes.map { String(format: "%02x", $0) }.joined()

        let wallet = ConnectedWallet(address: address, walletApp: "Local", connectedAt: Date())
        setConnected(wallet)
        print("✅ Wallet recovered from Keychain: \(address)")
    }

    // MARK: - Local wallet generation

    /// Generates an Ethereum key pair and stores it in the iOS Keychain.
    /// Uses SecRandomCopyBytes (Apple CSPRNG) — cryptographically unique every call.
    /// SECURITY: Each invocation produces a unique 256-bit private key.
    /// The probability of collision is 1/2^256 — effectively zero.
    private func generateLocalWallet() {
        // 1. Generate 32 cryptographically random bytes → private key
        var keyBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes)
        guard status == errSecSuccess else {
            print("❌ SecRandomCopyBytes failed: \(status)")
            return
        }
        // Safety check: ensure we didn't get all zeros (should never happen with CSPRNG)
        guard keyBytes.contains(where: { $0 != 0 }) else {
            print("❌ CRITICAL: SecRandomCopyBytes returned all zeros — aborting")
            return
        }

        // 2. Derive uncompressed public key via libsecp256k1 C API
        // Note: C #define macros (SECP256K1_CONTEXT_SIGN etc.) aren't importable in Swift.
        // SECP256K1_CONTEXT_NONE = 1 (SIGN/VERIFY are deprecated aliases for NONE).
        guard let ctx = secp256k1_context_create(UInt32(1)) else {
            print("❌ secp256k1_context_create returned nil")
            return
        }
        defer { secp256k1_context_destroy(ctx) }

        var pubkey = secp256k1_pubkey()
        guard secp256k1_ec_pubkey_create(ctx, &pubkey, keyBytes) == 1 else {
            print("❌ secp256k1_ec_pubkey_create failed")
            return
        }

        var serialized = [UInt8](repeating: 0, count: 65)
        var outputLen: Int = 65
        // SECP256K1_EC_UNCOMPRESSED = 2
        guard secp256k1_ec_pubkey_serialize(ctx, &serialized, &outputLen, &pubkey, UInt32(2)) == 1 else {
            print("❌ secp256k1_ec_pubkey_serialize failed")
            return
        }

        // 3. Keccak-256 of the 64-byte public key (skip the 0x04 prefix)
        let pubKeyNoPrefix = Data(serialized[1..<65])   // skip 0x04
        let hash = Keccak256.hash(data: pubKeyNoPrefix)

        // 4. Last 20 bytes = Ethereum address
        let addressBytes = hash.suffix(20)
        let address = "0x" + addressBytes.map { String(format: "%02x", $0) }.joined()

        // 5. Store private key in Keychain
        storePrivateKey(Data(keyBytes))

        // 6. Save as connected wallet
        let wallet = ConnectedWallet(
            address: address,
            walletApp: "Local",
            connectedAt: Date()
        )
        setConnected(wallet)
        print("✅ Local wallet generated: \(address)")
    }

    // MARK: - Keychain (private key storage)

    private func storePrivateKey(_ keyData: Data) {
        // Try update first (atomic, no gap where key doesn't exist)
        let searchQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: pkKeychainId,
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: keyData,
        ]
        let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttrs as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // No existing key → add new
            let addQuery: [String: Any] = [
                kSecClass as String:             kSecClassGenericPassword,
                kSecAttrAccount as String:       pkKeychainId,
                kSecValueData as String:         keyData,
                kSecAttrAccessible as String:    kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                print("⚠️ Keychain add failed: \(addStatus)")
            }
        } else if updateStatus != errSecSuccess {
            print("⚠️ Keychain update failed: \(updateStatus)")
        }
    }

    /// Deletes the private key from Keychain (user chose to store it themselves)
    func deletePrivateKey() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: pkKeychainId,
        ]
        SecItemDelete(query as CFDictionary)
    }

    func loadPrivateKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: pkKeychainId,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    // MARK: - App password (hashed with SHA-256)

    /// Validates password strength: min 8 chars, 1 uppercase, 1 lowercase, 1 digit.
    static func validatePasswordStrength(_ password: String) -> String? {
        if password.count < 8 { return "At least 8 characters" }
        if !password.contains(where: { $0.isUppercase }) { return "At least one uppercase letter" }
        if !password.contains(where: { $0.isLowercase }) { return "At least one lowercase letter" }
        if !password.contains(where: { $0.isNumber }) { return "At least one number" }
        return nil // valid
    }

    /// Save the password hash in Keychain using PBKDF2 (password-safe).
    /// Salt is stored alongside the hash: [32 bytes salt][32 bytes hash]
    func setPassword(_ password: String) {
        let salt = generateSalt()
        let hash = pbkdf2(password: password, salt: salt)
        let combined = salt + hash // 32 + 32 = 64 bytes
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: passwordKeychainId,
        ]
        SecItemDelete(query as CFDictionary) // remove old if any
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: passwordKeychainId,
            kSecValueData as String: combined,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    /// Verify a password against the stored PBKDF2 hash.
    /// Also supports legacy SHA256 hashes for backward compatibility.
    func verifyPassword(_ password: String) -> Bool {
        guard let stored = loadPasswordHash() else { return false }

        if stored.count == 64 {
            // New format: [32-byte salt][32-byte hash]
            let salt = stored.prefix(32)
            let expectedHash = stored.suffix(32)
            let candidateHash = pbkdf2(password: password, salt: Data(salt))
            return candidateHash == Data(expectedHash)
        } else if stored.count == 32 {
            // Legacy SHA256 — migrate on successful verify
            let legacyHash = sha256(password)
            if legacyHash == stored {
                // Re-hash with PBKDF2 for future verifications
                setPassword(password)
                return true
            }
            return false
        }
        return false
    }

    private func loadPasswordHash() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: passwordKeychainId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    private func generateSalt() -> Data {
        var salt = Data(count: 32)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return salt
    }

    /// PBKDF2-SHA256 with 100,000 iterations (password-safe)
    private func pbkdf2(password: String, salt: Data) -> Data {
        let passwordData = Data(password.utf8)
        var derivedKey = Data(count: 32)
        derivedKey.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { pwBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        100_000, // 100K iterations
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        return derivedKey
    }

    /// Legacy SHA256 (for backward compatibility only)
    private func sha256(_ input: String) -> Data {
        let digest = SHA256.hash(data: Data(input.utf8))
        return Data(digest)
    }

    // MARK: - Biometric authentication

    /// Asks the user to enable Face ID / Touch ID for transaction security.
    /// Call this once during onboarding.
    func requestBiometricSetup() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            print("⚠️ Biometrics not available: \(error?.localizedDescription ?? "unknown")")
            return false
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Activate Face ID to secure your transactions"
            )
            if success {
                biometricEnabled = true
                isUnlocked = true
            }
            return success
        } catch {
            print("⚠️ Biometric auth failed: \(error)")
            return false
        }
    }

    /// Authenticates before signing a transaction.
    /// Uses Face ID if enabled, otherwise requires password.
    /// Returns true if authentication succeeded.
    func authenticateForTransaction() async -> Bool {
        // If biometric is enabled, try Face ID first
        if biometricEnabled {
            let context = LAContext()
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: "Confirm transaction"
                )
                if success { return true }
            } catch {
                print("⚠️ Biometric auth failed: \(error)")
            }
            // Face ID failed — fall through to password if available
        }

        // If no password set and no biometric, allow (pre-password-setup state)
        guard hasPassword else { return !biometricEnabled }

        // Password authentication — handled via UI prompt
        // Set flag to trigger password prompt in the UI
        pendingPasswordAuth = true
        passwordAuthResult = nil

        // Wait for user to enter password (up to 60 seconds)
        let start = Date()
        while passwordAuthResult == nil && Date().timeIntervalSince(start) < 60 {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        let result = passwordAuthResult ?? false
        pendingPasswordAuth = false
        passwordAuthResult = nil
        return result
    }

    /// Set by authenticateForTransaction when password input is needed
    @Published var pendingPasswordAuth = false
    /// Set by the UI when user submits password for transaction auth
    var passwordAuthResult: Bool? = nil

    /// Called from UI when user enters password for transaction confirmation
    func submitTransactionPassword(_ password: String) -> Bool {
        let ok = verifyPassword(password)
        passwordAuthResult = ok
        return ok
    }

    /// Authenticate on app launch / foreground.
    /// Uses .deviceOwnerAuthentication → Face ID first, then falls back to device passcode.
    @Published var authError: String? = nil

    func authenticateAppLaunch() async {
        // If no biometric AND no password → unlock immediately (fresh install before password set)
        guard biometricEnabled || hasPassword else {
            isUnlocked = true
            return
        }
        // If password-only (no biometric), show lock screen and wait for password entry
        guard biometricEnabled else {
            // Lock screen will handle password input — don't auto-unlock
            return
        }
        // Prevent concurrent auth calls (system dialog can trigger scenePhase changes)
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        // Grace period: skip auth if app was backgrounded briefly (e.g. build cycle)
        if let bgTime = backgroundTimestamp, Date().timeIntervalSince(bgTime) < lockGracePeriod {
            isUnlocked = true
            backgroundTimestamp = nil
            return
        }
        let context = LAContext()
        // Use biometrics-only policy so iOS never falls back to the device passcode.
        // When Face ID fails, the user is shown our app password field in LockScreenView instead.
        context.localizedFallbackTitle = ""  // Hide "Use Passcode" button in Face ID dialog
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock Hyperview"
            )
            isUnlocked = success
            authError = success ? nil : "Authentication failed"
        } catch let error as LAError {
            isUnlocked = false
            backgroundTimestamp = nil
            switch error.code {
            case .userCancel:
                authError = "Authentication cancelled"
            case .biometryNotAvailable, .biometryNotEnrolled:
                // Face ID not available — LockScreenView will show password entry
                authError = "Biometrics unavailable — use your password"
            case .biometryLockout:
                authError = "Face ID locked — use your password"
            default:
                authError = "Face not recognized — try again or use password"
            }
        } catch {
            isUnlocked = false
            backgroundTimestamp = nil
            authError = "Authentication failed"
        }
    }

    /// Lock the app (called when going to background)
    /// Records timestamp — actual lock only enforced after grace period expires.
    func lockApp() {
        guard biometricEnabled || hasPassword else { return }
        backgroundTimestamp = Date()
        isUnlocked = false
    }

    // MARK: - Connect (external wallets)

    func connectWithDeepLink(walletApp: WalletApp, address: String) {
        let wallet = ConnectedWallet(
            address: address.lowercased(),
            walletApp: walletApp.rawValue,
            connectedAt: Date()
        )
        setConnected(wallet)
    }

    func connectManual(address: String) {
        guard address.hasPrefix("0x"), address.count == 42 else {
            errorMessage = "Invalid address (must start with 0x, 42 characters)"
            return
        }
        let wallet = ConnectedWallet(
            address: address.lowercased(),
            walletApp: "Manual",
            connectedAt: Date()
        )
        setConnected(wallet)
    }

    func disconnect() {
        connectedWallet = nil
        UserDefaults.standard.removeObject(forKey: walletKey)
        accountValueCache.removeAll()
        accountValue = 0
        perpValue    = 0
        spotValue    = 0
        dailyPnl     = 0
        stakingTier  = .none
        perpWithdrawable = 0
        spotTokenBalances = [:]
        spotTokenAvailable = [:]
        spotTokenEntryNtl = [:]
        activePositions = []
        mainDexPositions = []
        hip3Positions = []
        hip3PollTimer?.invalidate()
        hip3PollTimer = nil
        SessionKeyManager.shared.clearSessionKey()
    }

    // MARK: - HIP-3 Position Polling

    /// Start polling HIP-3 clearinghouse states every 10 seconds.
    /// Merges HIP-3 positions with main DEX positions into activePositions.
    func startHIP3PositionPolling() {
        guard hip3PollTimer == nil else { return }
        // Fetch immediately
        Task { await fetchHIP3Positions() }
        // Then every 30 seconds (reduced from 10s to lower API load)
        hip3PollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.fetchHIP3Positions()
            }
        }
    }

    func stopHIP3PositionPolling() {
        hip3PollTimer?.invalidate()
        hip3PollTimer = nil
    }

    /// Merge main + HIP-3 positions into activePositions
    func mergePositions() {
        activePositions = mainDexPositions + hip3Positions
        sharePositionsWithWidget()
    }

    /// Write active positions to the shared App Group container for the widget.
    private func sharePositionsWithWidget() {
        guard let defaults = UserDefaults(suiteName: "group.com.Hyperview.Hyperview") else { return }
        let data = activePositions.map { p -> [String: Any] in
            var d: [String: Any] = [
                "coin": p.coin,
                "size": p.size,
                "entry": p.entryPrice,
                "mark": p.markPrice,
                "pnl": p.unrealizedPnl,
                "lev": p.leverage
            ]
            if let liq = p.liquidationPx { d["liq"] = liq }
            return d
        }
        defaults.set(data, forKey: "widget_shared_positions")
        WidgetCenter.shared.reloadTimelines(ofKind: "PositionsWidget")
    }

    /// Dedupe lock: last position refresh timestamp
    private var lastPositionRefresh: Date = .distantPast

    /// Force an immediate refresh of main DEX positions via API (call after placing/closing orders)
    /// Deduplicates: won't re-fetch if called again within 1 second
    func refreshMainPositionsNow() {
        let now = Date()
        guard now.timeIntervalSince(lastPositionRefresh) > 1.0 else { return }
        lastPositionRefresh = now
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s delay
            await fetchMainPositions()
        }
    }

    private func fetchMainPositions() async {
        guard let address = connectedWallet?.address else { return }
        guard let url = URL(string: "https://api.hyperliquid.xyz/info") else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "type": "clearinghouseState",
            "user": address
        ])
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assetPositions = json["assetPositions"] as? [[String: Any]]
            else { return }
            let parsed: [PerpPosition] = assetPositions.compactMap { wrapper in
                guard let pos = wrapper["position"] as? [String: Any],
                      let coin = pos["coin"] as? String,
                      let sziStr = pos["szi"] as? String,
                      let szi = Double(sziStr), abs(szi) > 0.0000001, // Filter dust positions
                      let entryStr = pos["entryPx"] as? String,
                      let entry = Double(entryStr)
                else { return nil }
                let posValue = (pos["positionValue"] as? String).flatMap(Double.init) ?? 0
                let pnl = (pos["unrealizedPnl"] as? String).flatMap(Double.init) ?? 0
                let liqPx = (pos["liquidationPx"] as? String).flatMap(Double.init)
                let levVal = (pos["leverage"] as? [String: Any])?["value"] as? Int ?? 1
                let isCross = ((pos["leverage"] as? [String: Any])?["type"] as? String ?? "cross") == "cross"
                let marginUsed = (pos["marginUsed"] as? String).flatMap(Double.init) ?? 0
                let funding = (pos["cumFunding"] as? [String: Any])?["sinceOpen"] as? String
                let cumulFunding = funding.flatMap(Double.init) ?? 0
                return PerpPosition(
                    coin: coin, rawCoin: coin, size: szi, entryPrice: entry,
                    markPrice: posValue / max(abs(szi), 0.000001),
                    unrealizedPnl: pnl, leverage: levVal, isCross: isCross,
                    marginUsed: marginUsed,
                    liquidationPx: liqPx, cumulativeFunding: cumulFunding,
                    szDecimals: MarketsViewModel.szDecimals(for: coin)
                )
            }
            mainDexPositions = parsed
            mergePositions()
        } catch {
            print("[POSITIONS] Failed to refresh: \(error.localizedDescription)")
        }
    }

    /// Force an immediate HIP-3 position refresh (call after placing/closing HIP-3 orders)
    /// Deduplicates: won't re-fetch if called again within 1 second
    private var lastHIP3Refresh: Date = .distantPast

    func refreshHIP3PositionsNow() {
        let now = Date()
        guard now.timeIntervalSince(lastHIP3Refresh) > 1.0 else { return }
        lastHIP3Refresh = now
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            await fetchHIP3Positions()
        }
    }

    private func fetchHIP3Positions() async {
        guard let address = connectedWallet?.address else { return }

        do {
            let url = URL(string: "\(Configuration.ingestionBaseURL)/hip3-positions")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 10

            let body: [String: Any] = ["address": address]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? 0)
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            let positionsArray: [[String: Any]]
            if let arr = json["positions"] as? [[String: Any]] {
                positionsArray = arr
            } else if let arr = json["data"] as? [[String: Any]] {
                positionsArray = arr
            } else {
                print("[HIP3-DEBUG] Response: \(data.count) bytes, status 200")
                print("[HIP3-DEBUG] Could not find positions array in JSON keys: \(Array(json.keys))")
                hip3Positions = []
                mergePositions()
                print("⚡ Backend HIP-3: 0 markets from 1 request")
                return
            }

            var positions: [PerpPosition] = []

            for entry in positionsArray {
                let pos: [String: Any]

                if let directPos = entry["position"] as? [String: Any] {
                    pos = directPos
                } else if let assetPositions = entry["assetPositions"] as? [[String: Any]],
                          let firstWrapper = assetPositions.first,
                          let nestedPos = firstWrapper["position"] as? [String: Any] {
                    pos = nestedPos
                } else {
                    pos = entry
                }

                guard let coin = pos["coin"] as? String,
                      let sziStr = pos["szi"] as? String,
                      let szi = Double(sziStr), abs(szi) > 0.0000001,
                      let entryStr = pos["entryPx"] as? String,
                      let entryPx = Double(entryStr) else {
                    continue
                }

                let posValue = (pos["positionValue"] as? String).flatMap(Double.init) ?? 0
                let pnl = (pos["unrealizedPnl"] as? String).flatMap(Double.init) ?? 0
                let liqPx = (pos["liquidationPx"] as? String).flatMap(Double.init)
                let marginUsed = (pos["marginUsed"] as? String).flatMap(Double.init) ?? 0

                let leverageValue: Int = {
                    if let lev = pos["leverage"] as? Int { return lev }
                    if let lev = pos["leverage"] as? [String: Any],
                       let value = lev["value"] as? Int { return value }
                    return 1
                }()

                let isCross: Bool = {
                    if let cross = pos["isCross"] as? Bool { return cross }
                    if let lev = pos["leverage"] as? [String: Any] {
                        return (lev["type"] as? String ?? "cross") == "cross"
                    }
                    return true
                }()

                let cumulativeFunding: Double = {
                    if let funding = (pos["cumulativeFunding"] as? String).flatMap(Double.init) {
                        return funding
                    }
                    if let fundingStr = (pos["cumFunding"] as? [String: Any])?["sinceOpen"] as? String,
                       let funding = Double(fundingStr) {
                        return funding
                    }
                    return 0
                }()

                positions.append(
                    PerpPosition(
                        coin: coin,
                        rawCoin: coin,
                        size: szi,
                        entryPrice: entryPx,
                        markPrice: posValue / max(abs(szi), 0.000001),
                        unrealizedPnl: pnl,
                        leverage: leverageValue,
                        isCross: isCross,
                        marginUsed: marginUsed,
                        liquidationPx: liqPx,
                        cumulativeFunding: cumulativeFunding,
                        szDecimals: MarketsViewModel.szDecimals(for: coin)
                    )
                )
            }

            hip3Positions = positions
            mergePositions()
            print("⚡ Backend HIP-3: \(positions.count) markets from 1 request")

        } catch {
            print("[HIP3] Backend batch failed, falling back to direct: \(error.localizedDescription)")
            let states = await HyperliquidAPI.shared.fetchHIP3States(address: address)
            var positions: [PerpPosition] = []

            for (_, state) in states {
                guard let assetPositions = state["assetPositions"] as? [[String: Any]] else { continue }

                for wrapper in assetPositions {
                    guard let pos = wrapper["position"] as? [String: Any],
                          let coin = pos["coin"] as? String,
                          let sziStr = pos["szi"] as? String,
                          let szi = Double(sziStr), abs(szi) > 0.0000001,
                          let entryStr = pos["entryPx"] as? String,
                          let entry = Double(entryStr) else { continue }

                    let posValue = (pos["positionValue"] as? String).flatMap(Double.init) ?? 0
                    let pnl = (pos["unrealizedPnl"] as? String).flatMap(Double.init) ?? 0
                    let liqPx = (pos["liquidationPx"] as? String).flatMap(Double.init)
                    let levVal = (pos["leverage"] as? [String: Any])?["value"] as? Int ?? 1
                    let isCross = ((pos["leverage"] as? [String: Any])?["type"] as? String ?? "cross") == "cross"
                    let marginUsed = (pos["marginUsed"] as? String).flatMap(Double.init) ?? 0
                    let fundingStr = (pos["cumFunding"] as? [String: Any])?["sinceOpen"] as? String
                    let cumulFunding = fundingStr.flatMap(Double.init) ?? 0

                    positions.append(
                        PerpPosition(
                            coin: coin,
                            rawCoin: coin,
                            size: szi,
                            entryPrice: entry,
                            markPrice: posValue / max(abs(szi), 0.000001),
                            unrealizedPnl: pnl,
                            leverage: levVal,
                            isCross: isCross,
                            marginUsed: marginUsed,
                            liquidationPx: liqPx,
                            cumulativeFunding: cumulFunding,
                            szDecimals: MarketsViewModel.szDecimals(for: coin)
                        )
                    )
                }
            }

            hip3Positions = positions
            mergePositions()
        }
    }
    /// Creates a brand new wallet: backs up the old key, generates a fresh random one,
    /// and resets onboarding so the user sees the key backup screen.
    /// SECURITY: Uses SecRandomCopyBytes (CSPRNG) — every call produces a unique 256-bit key.
    /// SAFETY: The old private key is archived in Keychain before deletion, allowing recovery.
    /// Returns true if it's safe to create a new wallet (no funds on current one).
    var canSafelyCreateNewWallet: Bool {
        accountValue < 1.0 && perpValue < 1.0 && spotValue < 1.0
    }

    /// Error message explaining why wallet creation is blocked.
    var createWalletBlockedReason: String? {
        guard !canSafelyCreateNewWallet else { return nil }
        return "You have $\(String(format: "%.2f", accountValue)) on this wallet. Transfer all funds out and export your private key from Settings before creating a new wallet."
    }

    func createNewWallet() {
        // SAFETY: block if wallet has funds (prevent accidental fund loss)
        guard canSafelyCreateNewWallet else {
            print("🚨 createNewWallet BLOCKED: wallet has funds ($\(accountValue))")
            return
        }

        // 1. Archive old key before overwriting (safety net)
        archiveCurrentKey()

        // 2. Fully disconnect + wipe current key
        disconnect()
        deletePrivateKey()

        // 3. Generate a fresh random wallet
        generateLocalWallet()

        // 4. Reset onboarding so user sees the setup screens
        hasCompletedOnboarding = false
    }

    // MARK: - Key archiving (safety net)

    private let archivedKeysKeychainId = "com.hyperview.wallet.archivedkeys"

    /// Archives the current private key + address before creating a new wallet.
    /// Stored as JSON array in Keychain so old wallets can be recovered.
    private func archiveCurrentKey() {
        guard let keyData = loadPrivateKey(),
              let address = connectedWallet?.address else { return }

        let keyHex = keyData.map { String(format: "%02x", $0) }.joined()
        let entry: [String: String] = [
            "address": address,
            "key": keyHex,
            "archivedAt": ISO8601DateFormatter().string(from: Date())
        ]

        // Load existing archive
        var archive = loadArchivedKeys()
        // Don't duplicate
        if !archive.contains(where: { $0["address"]?.lowercased() == address.lowercased() }) {
            archive.append(entry)
        }

        // Save back
        if let data = try? JSONSerialization.data(withJSONObject: archive) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: archivedKeysKeychainId,
            ]
            SecItemDelete(query as CFDictionary)
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: archivedKeysKeychainId,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
            SecItemAdd(addQuery as CFDictionary, nil)
            print("🔑 [ARCHIVE] Archived key for \(address)")
        }
    }

    /// Load archived keys from Keychain.
    func loadArchivedKeys() -> [[String: String]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: archivedKeysKeychainId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else { return [] }
        return array
    }

    /// Restore an archived private key for a given address.
    /// Returns true if the key was found and restored.
    func restoreArchivedKey(address: String) -> Bool {
        let archive = loadArchivedKeys()
        guard let entry = archive.first(where: { $0["address"]?.lowercased() == address.lowercased() }),
              let keyHex = entry["key"] else { return false }

        // Convert hex to Data
        var keyBytes = [UInt8]()
        var hex = keyHex
        while hex.count >= 2 {
            let byte = String(hex.prefix(2))
            hex = String(hex.dropFirst(2))
            if let b = UInt8(byte, radix: 16) { keyBytes.append(b) }
        }
        let keyData = Data(keyBytes)
        guard keyData.count == 32 else { return false }

        // Verify it matches the expected address
        guard let derived = Self.deriveAddress(from: keyData),
              derived.lowercased() == address.lowercased() else { return false }

        // Restore key + wallet
        storePrivateKey(keyData)
        let wallet = ConnectedWallet(address: address, walletApp: "Local", connectedAt: Date())
        setConnected(wallet)
        print("✅ [RESTORE] Restored key for \(address)")
        return true
    }

    // MARK: - Switch account (for sub-accounts)

    func switchToAddress(_ address: String) {
        let wallet = ConnectedWallet(address: address, walletApp: "Local", connectedAt: Date())
        // Unsubscribe old, clear data, switch
        if let oldAddr = connectedWallet?.address {
            WebSocketManager.shared.unsubscribeWebData2(address: oldAddr)
        }
        // Clear position/token state (belongs to the old account).
        // accountValue is NOT cleared — per-address cache keeps the last known value
        // for each address, so switching back shows the cached value instantly.
        mainDexPositions = []
        hip3Positions = []
        activePositions = []
        dailyPnl = 0
        perpWithdrawable = 0
        spotTokenBalances = [:]
        spotTokenAvailable = [:]
        spotTokenEntryNtl = [:]
        // Reset so subscribeToSpotBalanceWS re-subscribes for the new address
        webData2Subscribed = false
        connectedWallet = wallet
        syncAccountValueFromCache()   // Instantly show cached balance for the new address
        isPortfolioMargin = cachedIsPortfolioMargin(for: address) ?? false
        // Don't persist to UserDefaults — sub-account switch is temporary
        // WebSocket subscription happens inside refreshAccountState → subscribeToSpotBalanceWS
        Task {
            await refreshAccountState()
        }
    }

    /// Fetch and set the abstraction mode (Classic/Portfolio Margin) for a given address.
    @discardableResult
    func fetchAbstractionMode(for address: String) async -> Bool? {
        guard let url = URL(string: "https://api.hyperliquid.xyz/info") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "type": "userAbstraction",
            "user": address
        ])
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let str = try? JSONSerialization.jsonObject(with: data) as? String else { return nil }

        let pm = (str == "portfolioMargin")
        portfolioMarginByAddress[address.lowercased()] = pm

        if connectedWallet?.address.lowercased() == address.lowercased() {
            isPortfolioMargin = pm
            // Do NOT recompute accountValue — portfolio API is the sole source of truth.
        }

        print("[ABSTRACTION] \(address.prefix(10))... = \(str) → PM=\(pm)")
        return pm
    }

    func cachedIsPortfolioMargin(for address: String) -> Bool? {
        portfolioMarginByAddress[address.lowercased()]
    }

    // totalAccountValue / recomputeAccountValueForActiveAccount REMOVED.
    // accountValue is set exclusively from the portfolio API (accountValueHistory.last).
    // This eliminates all PM/non-PM formula inconsistencies.

    /// Prefetch sub-accounts and cache the raw JSON so Settings can display them instantly.
    func prefetchSubAccounts(for address: String) async {
        guard let url = URL(string: "https://api.hyperliquid.xyz/info") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "type": "subAccounts",
            "user": address
        ])
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        cacheSubAccounts(arr, for: address)
        print("[SUB-ACCOUNTS] Prefetched \(arr.count) sub-accounts for \(address.prefix(10))…")
    }

    // MARK: - Import private key (TEMPORARY — for testing only)

    /// Save current wallet's key + address to a UserDefaults slot
    private func saveCurrentToSlot() {
        guard let addr = connectedWallet?.address else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: pkKeychainId,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let keyData = item as? Data else { return }
        let hex = keyData.map { String(format: "%02x", $0) }.joined()

        var keys = UserDefaults.standard.stringArray(forKey: "hl_saved_wallet_keys") ?? []
        // Don't duplicate
        let exists = keys.contains { UserDefaults.standard.string(forKey: "hl_wallet_addr_\($0)")?.lowercased() == addr.lowercased() }
        if !exists {
            let slot = "wallet_\(keys.count)"
            keys.append(slot)
            UserDefaults.standard.set(keys, forKey: "hl_saved_wallet_keys")
            UserDefaults.standard.set(addr, forKey: "hl_wallet_addr_\(slot)")
            UserDefaults.standard.set(hex, forKey: "hl_wallet_key_\(slot)")
            UserDefaults.standard.set(addr.prefix(8) + "…", forKey: "hl_wallet_label_\(slot)")
            print("✅ [SLOT] Saved \(addr.prefix(10))… to \(slot)")
        }
    }

    /// Switch to a saved wallet by slot key
    func switchToSavedWallet(slot: String) {
        guard let hex = UserDefaults.standard.string(forKey: "hl_wallet_key_\(slot)"),
              let addr = UserDefaults.standard.string(forKey: "hl_wallet_addr_\(slot)")
        else { return }
        // Save current wallet first
        saveCurrentToSlot()
        // Load target key
        var keyBytes: [UInt8] = []
        var tmp = hex
        while tmp.count >= 2 {
            let byte = String(tmp.prefix(2))
            tmp = String(tmp.dropFirst(2))
            if let b = UInt8(byte, radix: 16) { keyBytes.append(b) }
        }
        let keyData = Data(keyBytes)
        guard keyData.count == 32 else { return }
        storePrivateKey(keyData)
        activeVaultAddress = nil // Reset vault — switching to a master wallet
        let wallet = ConnectedWallet(address: addr, walletApp: "Local", connectedAt: Date())
        setConnected(wallet)
        print("✅ [SWITCH] Switched to \(addr.prefix(10))…")
    }

    func importPrivateKey(_ hexKey: String) -> Bool {
        var hex = hexKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("0x") { hex = String(hex.dropFirst(2)) }
        var keyBytes: [UInt8] = []
        var tmp = hex
        while tmp.count >= 2 {
            let byte = String(tmp.prefix(2))
            tmp = String(tmp.dropFirst(2))
            if let b = UInt8(byte, radix: 16) { keyBytes.append(b) }
        }
        let keyData = Data(keyBytes)
        guard keyData.count == 32 else {
            print("❌ [IMPORT] Invalid key length: \(keyData.count)")
            return false
        }
        guard let address = Self.deriveAddress(from: keyData) else {
            print("❌ [IMPORT] Failed to derive address")
            return false
        }
        // Save current wallet to slot before overwriting
        saveCurrentToSlot()
        // Save imported wallet to slot too
        var keys = UserDefaults.standard.stringArray(forKey: "hl_saved_wallet_keys") ?? []
        let exists = keys.contains { UserDefaults.standard.string(forKey: "hl_wallet_addr_\($0)")?.lowercased() == address.lowercased() }
        if !exists {
            let slot = "wallet_\(keys.count)"
            keys.append(slot)
            UserDefaults.standard.set(keys, forKey: "hl_saved_wallet_keys")
            UserDefaults.standard.set(address, forKey: "hl_wallet_addr_\(slot)")
            UserDefaults.standard.set(hex, forKey: "hl_wallet_key_\(slot)")
            UserDefaults.standard.set("Imported", forKey: "hl_wallet_label_\(slot)")
        }
        storePrivateKey(keyData)
        let wallet = ConnectedWallet(address: address, walletApp: "Local", connectedAt: Date())
        setConnected(wallet)
        print("✅ [IMPORT] Imported key for \(address)")
        return true
    }

    // MARK: - Session key

    func signSessionKey(signature: String) {
        SessionKeyManager.shared.storeSessionSignature(signature)
    }

    // MARK: - Deep link helpers

    func openWalletApp(_ app: WalletApp) {
        guard let scheme = app.scheme,
              let url = URL(string: scheme) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Account refresh

    private static let backendBaseURL = Configuration.backendBaseURL
    private var webData2Subscribed = false
    private var spotRefreshTimer: Timer?

    /// Periodic REST refresh of spot balance + total equity every 30s.
    /// REST is the sole source of truth for spotValue and accountValue.
    private func startSpotRefreshTimer() {
        guard spotRefreshTimer == nil else { return }
        spotRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let addr = self.connectedWallet?.address else { return }
                let capturedAddr = addr
                let spotURL = URL(string: "\(Self.backendBaseURL)/spot-balance/\(capturedAddr)")!
                if let (data, _) = try? await URLSession.shared.data(from: spotURL),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let balances = json["balances"] as? [[String: Any]] {
                    let val = await self.computeSpotValue(balances: balances)
                    // Only apply if still the active account
                    guard self.connectedWallet?.address == capturedAddr else { return }
                    if val != self.spotValue {
                        self.spotValue = val
                        // Do NOT recompute accountValue — portfolio API is the sole source of truth.
                        UserDefaults.standard.set(self.spotValue, forKey: "cached_spotValue")
                    }
                }
            }
        }
    }

    /// Subscribe to webData2 WebSocket for real-time spot balance updates.
    /// Called once after wallet is connected.
    func subscribeToSpotBalanceWS() {
        guard let address = connectedWallet?.address, !webData2Subscribed else { return }
        webData2Subscribed = true

        let ws = WebSocketManager.shared
        ws.connect()
        ws.subscribeWebData2(address: address)

        // Start HIP-3 position polling alongside main DEX WebSocket
        startHIP3PositionPolling()

        ws.onSpotBalance = { [weak self] balances in
            guard let self else { return }
            Task { @MainActor in
                // Update token-level balances only (for Trade tab, Send asset UI).
                // Does NOT update spotValue or accountValue — those come from REST only,
                // to prevent partial WebSocket updates from overwriting the correct total.
                self.updateSpotTokenBalances(from: balances)
            }
        }
    }

    func refreshAccountState() async {
        guard let address = connectedWallet?.address else { return }

        // Capture the address we are refreshing for.
        // After every async suspension, verify it is still the active account.
        // If the user switched accounts while we were loading, discard the stale result
        // to prevent a sub-account's values from polluting the master's display.
        let refreshAddress = address

        // Subscribe to webData2 for real-time position updates (one-time)
        subscribeToSpotBalanceWS()

        // Fetch abstraction mode from userAbstraction (used by total-equity formula).
        async let abstractionTask: Bool? = fetchAbstractionMode(for: refreshAddress)

        // For sub-accounts, fetch directly from HL API (backend may not have them)
        if activeVaultAddress != nil {
            // Fetch positions/spot AND portfolio API in parallel for speed.
            // Portfolio API is the source of truth for accountValue (same as WalletView).
            async let directTask: () = refreshAccountStateDirect()
            async let portfolioTask: [[String: Any]] = {
                (try? await HyperliquidAPI.shared.fetchPortfolio(address: refreshAddress)) ?? []
            }()

            await directTask
            let portfolioData = await portfolioTask
            _ = await abstractionTask

            guard connectedWallet?.address == refreshAddress else {
                print("[BALANCE] ⚠️ Account changed during refresh, discarding stale sub-account result")
                return
            }

            // Use portfolio API accountValueHistory as the single source of truth
            // — this is the exact same value WalletView/PortfolioChartView displays.
            var gotPortfolioValue = false
            for entry in portfolioData {
                guard let period = entry["period"] as? String, period == "day" else { continue }
                if let avh = entry["accountValueHistory"] as? [Any],
                   let lastPair = avh.last as? [Any],
                   lastPair.count >= 2 {
                    if let d = lastPair[1] as? Double { setAccountValue(d, for: refreshAddress); gotPortfolioValue = true }
                    else if let s = lastPair[1] as? String, let d = Double(s) { setAccountValue(d, for: refreshAddress); gotPortfolioValue = true }
                }
                if let pnlHistory = entry["pnlHistory"] as? [Any],
                   let lastPair = pnlHistory.last as? [Any],
                   lastPair.count >= 2 {
                    if let d = lastPair[1] as? Double { dailyPnl = d }
                    else if let s = lastPair[1] as? String, let d = Double(s) { dailyPnl = d }
                }
                break
            }

            // If portfolio API returned no data, keep previous accountValue — do NOT recompute from formula.
            if !gotPortfolioValue {
                print("[BALANCE] ⚠️ Portfolio API empty for \(refreshAddress.prefix(10))…, keeping previous value")
            }

            print("[BALANCE] sub-account \(refreshAddress.prefix(10))… accountValue=\(accountValue) (portfolio=\(gotPortfolioValue))")
            UserDefaults.standard.set(perpValue, forKey: "cached_perpValue")
            UserDefaults.standard.set(spotValue, forKey: "cached_spotValue")
            UserDefaults.standard.set(accountValue, forKey: "cached_accountValue")
            return
        }

        // Use backend /wallet/:address — one request, backend handles HL API rate limits
        let backendURL = URL(string: "\(Self.backendBaseURL)/wallet/\(address)")!
        var req = URLRequest(url: backendURL)
req.timeoutInterval = 5

do {
    let (data, _) = try await URLSession.shared.data(for: req)

    // After network await: verify this is still the active account
    guard connectedWallet?.address == refreshAddress else {
        print("[BALANCE] ⚠️ Account changed during backend fetch, discarding stale result for \(refreshAddress.prefix(10))…")
        return
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

    // Parse perp account value
    if let state = json["state"] as? [String: Any],
       let marginSummary = state["marginSummary"] as? [String: Any],
       let valStr = marginSummary["accountValue"] as? String,
       let val = Double(valStr) {
        perpValue = val
            }

            // Parse spot value using allMids for pricing
            var gotSpot = false
            if let spot = json["spot"] as? [String: Any],
               let balances = spot["balances"] as? [[String: Any]],
               !balances.isEmpty {
                let spotVal = await computeSpotValue(balances: balances)
                // Re-check after async computeSpotValue
                guard connectedWallet?.address == refreshAddress else {
                    print("[BALANCE] ⚠️ Account changed during spot compute, discarding")
                    return
                }
                print("[BALANCE-BACKEND] spot=\(spotVal) from backend")
                spotValue = spotVal
                gotSpot = true
            }

            // If spot empty, schedule a delayed retry via /spot-balance (after startup rush)
            if !gotSpot && spotValue == 0 {
                let delayAddr = refreshAddress
                print("[BALANCE] Spot empty, scheduling delayed /spot-balance in 3s...")
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard let self else { return }
                    // Only apply if this is still the active account
                    guard self.connectedWallet?.address == delayAddr else {
                        print("[BALANCE-DELAYED] ⚠️ Account changed, discarding delayed result for \(delayAddr.prefix(10))…")
                        return
                    }
                    let spotURL = URL(string: "\(Self.backendBaseURL)/spot-balance/\(delayAddr)")!
                    if let (data, _) = try? await URLSession.shared.data(from: spotURL),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let balances = json["balances"] as? [[String: Any]],
                       !balances.isEmpty {
                        let val = await self.computeSpotValue(balances: balances)
                        guard self.connectedWallet?.address == delayAddr else { return }
                        if val > 0 {
                            await MainActor.run {
                                self.spotValue = val
                                // Do NOT recompute accountValue — portfolio API is the sole source of truth.
                                UserDefaults.standard.set(self.spotValue, forKey: "cached_spotValue")
                                print("[BALANCE-DELAYED] spot=\(val)")
                            }
                        }
                    }
                }
            }

            // Parse staking tier
            if let staking = json["staking"] as? [String: Any],
               let summary = staking["summary"] as? [String: Any],
               let delegated = summary["delegated"] as? String,
               let val = Double(delegated) {
                stakingTier = tierFor(hypeStaked: val)
            }

        } catch {
            print("[BALANCE] Backend failed: \(error.localizedDescription), falling back to direct API")
            guard connectedWallet?.address == refreshAddress else { return }
            await refreshAccountStateDirect()
        }

        // Final guard: only write total if still the active account
        guard connectedWallet?.address == refreshAddress else {
            print("[BALANCE] ⚠️ Account changed before final write, discarding")
            return
        }
        _ = await abstractionTask

        // Portfolio API is the SOLE source of truth for accountValue (same as WalletView).
        // Also extract dailyPnl from the same response.
        do {
            let portfolioData = try await HyperliquidAPI.shared.fetchPortfolio(address: address)
            guard connectedWallet?.address == refreshAddress else {
                print("[BALANCE] ⚠️ Account changed during portfolio fetch, discarding")
                return
            }
            for entry in portfolioData {
                guard let period = entry["period"] as? String, period == "day" else { continue }
                // Account value from portfolio history
                if let avh = entry["accountValueHistory"] as? [Any],
                   let lastPair = avh.last as? [Any],
                   lastPair.count >= 2 {
                    if let d = lastPair[1] as? Double { setAccountValue(d, for: refreshAddress) }
                    else if let s = lastPair[1] as? String, let d = Double(s) { setAccountValue(d, for: refreshAddress) }
                }
                // Daily PnL
                if let pnlHistory = entry["pnlHistory"] as? [Any],
                   let lastPair = pnlHistory.last as? [Any],
                   lastPair.count >= 2 {
                    if let d = lastPair[1] as? Double { dailyPnl = d }
                    else if let s = lastPair[1] as? String, let d = Double(s) { dailyPnl = d }
                }
                break
            }
        } catch {
            // Portfolio API failed — keep previous accountValue, do NOT recompute from formula.
            print("[BALANCE] ⚠️ Portfolio API failed: \(error.localizedDescription), keeping previous value")
        }
        print("[BALANCE] accountValue=\(accountValue) perpValue=\(perpValue) spotValue=\(spotValue)")

        // Persist — always save, including zero balances (so stale cache gets cleared)
        UserDefaults.standard.set(perpValue, forKey: "cached_perpValue")
        UserDefaults.standard.set(spotValue, forKey: "cached_spotValue")
        UserDefaults.standard.set(accountValue, forKey: "cached_accountValue")

        // Auto-set referral code only when wallet has funds (Hyperliquid requires a deposit first)
        // Check multiple signals: accountValue, perpValue, spotValue, or any spot token balance
        let hasFunds = accountValue > 0 || perpValue > 0 || spotValue > 0
            || spotTokenBalances.values.contains(where: { $0 > 0 })
        print("[referral] hasFunds=\(hasFunds) accountValue=\(accountValue) perpValue=\(perpValue) spotValue=\(spotValue) spotTokens=\(spotTokenBalances.count)")
        if hasFunds {
            // Detached task — survives even if the parent refreshAccountState task is cancelled
            let addr = address
            Task.detached { @MainActor [weak self] in
                await self?.autoSetReferral(address: addr)
                await self?.autoApproveBuilderFee()
            }
        }
    }

    /// Update per-token spot balances from WebSocket data (for Trade tab, Send asset UI).
    /// Merges into existing state. Does NOT update spotValue or accountValue.
    private func updateSpotTokenBalances(from balances: [[String: Any]]) {
        for b in balances {
            guard let coin = b["coin"] as? String else { continue }
            let amount: Double
            if let s = b["total"] as? String, let d = Double(s) { amount = d }
            else if let d = b["total"] as? Double { amount = d }
            else if let n = b["total"] as? NSNumber { amount = n.doubleValue }
            else { continue }

            if abs(amount) > 0.0000001 {
                spotTokenBalances[coin] = amount
                let hold: Double
                if let s = b["hold"] as? String, let d = Double(s) { hold = d }
                else if let d = b["hold"] as? Double { hold = d }
                else if let n = b["hold"] as? NSNumber { hold = n.doubleValue }
                else { hold = 0 }
                spotTokenAvailable[coin] = max(0, amount - hold)
                if let s = b["entryNtl"] as? String, let d = Double(s) { spotTokenEntryNtl[coin] = d }
                else if let d = b["entryNtl"] as? Double { spotTokenEntryNtl[coin] = d }
                else if let n = b["entryNtl"] as? NSNumber { spotTokenEntryNtl[coin] = n.doubleValue }
            } else {
                spotTokenBalances.removeValue(forKey: coin)
                spotTokenAvailable.removeValue(forKey: coin)
                spotTokenEntryNtl.removeValue(forKey: coin)
            }
        }
    }

    /// Compute spot holdings USD value from REST balance array.
    /// Uses allMids for current market prices. Called ONLY from REST paths.
    /// Also populates spotTokenBalances/spotTokenAvailable/spotTokenEntryNtl.
    private func computeSpotValue(balances: [[String: Any]]) async -> Double {
        var midPrices = WebSocketManager.shared.latestMidPrices

        // At startup, WebSocket allMids hasn't arrived yet — fetch directly.
        if midPrices.isEmpty {
            let apiURL = URL(string: "https://api.hyperliquid.xyz/info")!
            let body: [String: Any] = ["type": "allMids"]
            if let data = try? await HyperliquidAPI.shared.post(url: apiURL, body: body),
               let mids = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                var fetched: [String: Double] = [:]
                for (coin, priceStr) in mids {
                    if let p = Double(priceStr) { fetched[coin] = p }
                }
                midPrices = fetched
                WebSocketManager.shared.latestMidPrices = fetched
            }
        }

        var tokenBals: [String: Double] = [:]
        var tokenAvail: [String: Double] = [:]
        var tokenEntry: [String: Double] = [:]
        let stables: Set<String> = ["USDC", "USDH", "USDT", "USDT0", "USDE"]

        // Parse balances (REST sends "total" as String)
        for b in balances {
            guard let coin = b["coin"] as? String,
                  let totStr = b["total"] as? String,
                  let amount = Double(totStr),
                  abs(amount) > 0.0000001
            else { continue }

            tokenBals[coin] = amount
            let hold = Double(b["hold"] as? String ?? "0") ?? 0
            tokenAvail[coin] = max(0, amount - hold)
            if let entryNtlStr = b["entryNtl"] as? String,
               let entryNtl = Double(entryNtlStr) {
                tokenEntry[coin] = entryNtl
            }
        }

        // Compute total from all tokens
        var total: Double = 0
        for (coin, amount) in tokenBals {
            if stables.contains(coin) {
                total += amount
            } else {
                let priceCoin = Self.spotToPerpName[coin] ?? coin
                if let price = midPrices[priceCoin], price > 0 {
                    total += amount * price
                }
            }
        }
        print("[SPOT-REST] TOTAL=$\(total) tokens=\(tokenBals.count)")
        spotTokenBalances = tokenBals
        spotTokenAvailable = tokenAvail
        spotTokenEntryNtl = tokenEntry
        return total
    }

    /// Dedicated URLSession for spot balance — doesn't compete with shared session
    private static let spotSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 4
        return URLSession(configuration: config)
    }()

    /// Fetch spot value using a DEDICATED session (bypasses shared connection pool)
    private func fetchSpotValueDedicated(address: String) async -> Double {
        let apiURL = URL(string: "https://api.hyperliquid.xyz/info")!

        // Fetch spot balances with dedicated session
        var spotReq = URLRequest(url: apiURL)
        spotReq.httpMethod = "POST"
        spotReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        spotReq.httpBody = try? JSONSerialization.data(withJSONObject: ["type": "spotClearinghouseState", "user": address])

        var midsReq = URLRequest(url: apiURL)
        midsReq.httpMethod = "POST"
        midsReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        midsReq.httpBody = try? JSONSerialization.data(withJSONObject: ["type": "allMids"])

        do {
            async let spotTask = Self.spotSession.data(for: spotReq)
            async let midsTask = Self.spotSession.data(for: midsReq)

            let (spotData, _) = try await spotTask
            let (midsData, _) = try await midsTask

            guard let spotJson = try JSONSerialization.jsonObject(with: spotData) as? [String: Any],
                  let balances = spotJson["balances"] as? [[String: Any]],
                  !balances.isEmpty,
                  let mids = try JSONSerialization.jsonObject(with: midsData) as? [String: String]
            else { return 0 }

            var midPrices: [String: Double] = [:]
            for (coin, priceStr) in mids {
                if let p = Double(priceStr) { midPrices[coin] = p }
            }

            let stables: Set<String> = ["USDC", "USDH", "USDT", "USDT0", "USDE"]
            var total: Double = 0
            for b in balances {
                guard let coin = b["coin"] as? String,
                      let totStr = b["total"] as? String,
                      let amount = Double(totStr), abs(amount) > 0.0000001
                else { continue }
                if stables.contains(coin) {
                    total += amount
                } else {
                    let priceCoin = Self.spotToPerpName[coin] ?? coin
                    if let price = midPrices[priceCoin], price > 0 {
                        total += amount * price
                    }
                }
            }
            return total
        } catch {
            print("[SPOT-DEDICATED] Failed: \(error.localizedDescription)")
            return 0
        }
    }

    /// Fallback: direct API calls (used when backend is down)
    private func refreshAccountStateDirect() async {
        guard let address = connectedWallet?.address else { return }
        let capturedAddr = address

        // Fetch perp state and spot value IN PARALLEL for faster display
        async let perpTask: [String: Any]? = try? HyperliquidAPI.shared.fetchUserState(address: capturedAddr)
        async let spotTask: Double = fetchSpotValue(address: capturedAddr)

        let perpState = await perpTask
        let spotVal = await spotTask

        // Guard: discard if account changed during fetch
        guard connectedWallet?.address == capturedAddr else {
            print("[BALANCE] ⚠️ Account changed during refreshAccountStateDirect, discarding stale result")
            return
        }

        if let state = perpState,
           let ms = state["marginSummary"] as? [String: Any],
           let valStr = ms["accountValue"] as? String,
           let val = Double(valStr) {
            perpValue = val
        }
        // Always set spotValue — even if 0 — to prevent stale values from previous account
        spotValue = spotVal
        print("[BALANCE-DIRECT] addr=\(capturedAddr.prefix(10))… perp=\(perpValue) spot=\(spotValue)")
    }

    /// Fetch HYPE balance on HyperEVM and convert to USD value.
    private func fetchEVMValue(address: String) async -> Double {
        guard let balance = try? await HyperEVMRPC.shared.getBalance(address: address),
              balance > 0 else { return 0 }
        // Get HYPE price from allMids
        let apiURL = URL(string: "https://api.hyperliquid.xyz/info")!
        let body: [String: Any] = ["type": "allMids"]
        guard let data = try? await HyperliquidAPI.shared.post(url: apiURL, body: body),
              let mids = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let priceStr = mids["HYPE"],
              let price = Double(priceStr) else { return 0 }
        return balance * price
    }

    /// Wrapped spot coin → perp/allMids name mapping
    private static let spotToPerpName: [String: String] = [
        "UBTC": "BTC", "UETH": "ETH", "USOL": "SOL",
        "UFART": "FARTCOIN", "UPUMP": "PUMP", "HPENGU": "PENGU",
        "UBONK": "BONK", "UENA": "ENA", "UMON": "MON",
        "UZEC": "ZEC", "MMOVE": "MOVE", "UDZ": "DZ",
    ]

    /// Fetch spot holdings USD value from spotClearinghouseState.
    /// Uses live mid prices from allMids for accurate valuation.
    private func fetchSpotValue(address: String) async -> Double {
        let apiURL = URL(string: "https://api.hyperliquid.xyz/info")!

        // Fetch spot balances + mid prices in parallel
        async let spotTask: (Data?, Any?) = {
            let body: [String: Any] = ["type": "spotClearinghouseState", "user": address]
            let data = try? await HyperliquidAPI.shared.post(url: apiURL, body: body)
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            return (data, json)
        }()
        async let midsTask: [String: Double] = {
            let body: [String: Any] = ["type": "allMids"]
            guard let data = try? await HyperliquidAPI.shared.post(url: apiURL, body: body),
                  let mids = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else { return [:] }
            var prices: [String: Double] = [:]
            for (coin, priceStr) in mids {
                if let p = Double(priceStr) { prices[coin] = p }
            }
            return prices
        }()

        let (_, spotJsonRaw) = await spotTask
        let midPrices = await midsTask

        guard let spotJson = spotJsonRaw as? [String: Any],
              let balances = spotJson["balances"] as? [[String: Any]]
        else { return 0 }

        let stables: Set<String> = ["USDC", "USDH", "USDT", "USDT0", "USDE"]
        var total: Double = 0
        for b in balances {
            guard let coin = b["coin"] as? String,
                  let totStr = b["total"] as? String,
                  let amount = Double(totStr), abs(amount) > 0.0000001
            else { continue }

            if stables.contains(coin) {
                // Stablecoins = face value (positive for holdings, negative for borrows)
                total += amount
            } else {
                // Non-stablecoins: use current market price
                let priceCoin = Self.spotToPerpName[coin] ?? coin
                if let price = midPrices[priceCoin], price > 0 {
                    total += amount * price
                }
            }
        }
        return total
    }

    // MARK: - Private

    private func setConnected(_ wallet: ConnectedWallet) {
        // Unsubscribe WebSocket from old address
        if let oldAddr = connectedWallet?.address {
            WebSocketManager.shared.unsubscribeWebData2(address: oldAddr)
        }
        // Clear old data
        mainDexPositions = []
        hip3Positions = []
        activePositions = []
        webData2Subscribed = false

        connectedWallet = wallet
        syncAccountValueFromCache()   // Instantly show cached balance (if revisiting)
        isPortfolioMargin = cachedIsPortfolioMargin(for: wallet.address) ?? false
        if let data = try? JSONEncoder().encode(wallet) {
            UserDefaults.standard.set(data, forKey: walletKey)
        }
        // WebSocket subscription happens inside refreshAccountState → subscribeToSpotBalanceWS
        // Do NOT subscribe here to avoid double-subscription or orphaned subs.
        Task {
            await refreshAccountState()
            // Prefetch sub-accounts in background so Settings opens instantly
            await prefetchSubAccounts(for: wallet.address)
        }
        // Register with backend analytics
        registerAnalytics(address: wallet.address)
    }

    private func loadSavedWallet() {
        guard let data = UserDefaults.standard.data(forKey: walletKey),
              let wallet = try? JSONDecoder().decode(ConnectedWallet.self, from: data)
        else { return }
        connectedWallet = wallet
        // Seed per-address cache from UserDefaults so balance shows instantly on launch
        let cachedAV = UserDefaults.standard.double(forKey: "cached_accountValue")
        if cachedAV > 0 {
            setAccountValue(cachedAV, for: wallet.address)
        }
        // Refresh balances on app launch (fetchAbstractionMode is called inside)
        Task {
            await refreshAccountState()
            // Prefetch sub-accounts in background so Settings opens instantly
            await prefetchSubAccounts(for: wallet.address)
        }
        // Heartbeat on app launch
        registerAnalytics(address: wallet.address)
    }

    // MARK: - Auto referral

    // Versioned key — bump version to force retry for all existing wallets
    // v1 = initial (code didn't exist yet), v2 = code HYPERVIEW created, retry all
    private static let referralSetKey = "hl_referral_set_v2"

    /// Sets referral code HYPERVIEW on this wallet.
    /// Called from refreshAccountState() ONLY when wallet has funds,
    /// because Hyperliquid requires a deposit before accepting setReferrer.
    private func autoSetReferral(address: String) async {
        // Only for wallets where we have a private key
        guard let keyData = loadPrivateKey() else {
            print("[referral] ⏭ Skipped: no private key")
            return
        }
        // Use the address derived from the key (not the connected wallet address, which could be stale)
        guard let keyAddress = Self.deriveAddress(from: keyData) else {
            print("[referral] ⏭ Skipped: failed to derive address from key")
            return
        }
        let addr = keyAddress.lowercased()
        print("[referral] Using key-derived address: \(addr) (connected: \(address))")
        // Only once per address (after successful confirmation)
        var done = UserDefaults.standard.stringArray(forKey: Self.referralSetKey) ?? []
        guard !done.contains(addr) else {
            print("[referral] ⏭ Already set for \(String(addr.prefix(10)))")
            return
        }

        print("[referral] 🔄 Attempting setReferrer code=\(HyperliquidAPI.referralCode) for \(String(addr.prefix(10)))...")

        do {
            let payload = try await TransactionSigner.signSetReferrer(code: HyperliquidAPI.referralCode)
            print("[referral] ✅ Signed payload, posting to API...")
            let result = try await TransactionSigner.postAction(payload)
            let status = result["status"] as? String ?? ""
            let response: String
            if let respStr = result["response"] as? String {
                response = respStr
            } else if let respDict = result["response"] as? [String: Any] {
                response = String(describing: respDict)
            } else {
                response = String(describing: result)
            }
            print("[referral] API response: status=\(status) response=\(response)")

            // Mark as done only if actually successful or user already has a referrer
            if status == "ok" || response.contains("already") || response.contains("referrer") || response.contains("success") {
                done.append(addr)
                UserDefaults.standard.set(done, forKey: Self.referralSetKey)
                print("[referral] ✅ Referral set for \(String(addr.prefix(10)))")
            } else if response.contains("deposit") || response.contains("need") {
                print("[referral] ⚠️ Wallet needs deposit first, will retry when funds arrive")
            } else {
                print("[referral] ⚠️ Unknown response, will retry next refresh: \(response)")
            }
        } catch {
            print("[referral] ❌ setReferrer failed (will retry): \(error)")
        }
    }

    // MARK: - Auto-approve builder fee

    private static let builderFeeApprovedKey = "builderFeeApprovedAddresses"

    private func autoApproveBuilderFee() async {
        guard let keyData = loadPrivateKey(),
              let keyAddress = Self.deriveAddress(from: keyData) else {
            return
        }
        let addr = keyAddress.lowercased()

        // Reset stale cache from previous bug (response.contains("approved") false positive)
        let resetKey = "builderFeeApprovedCacheReset_v2"
        if !UserDefaults.standard.bool(forKey: resetKey) {
            UserDefaults.standard.removeObject(forKey: Self.builderFeeApprovedKey)
            UserDefaults.standard.set(true, forKey: resetKey)
            print("[builder] 🔄 Cleared stale approval cache")
        }

        // Only once per address
        var done = UserDefaults.standard.stringArray(forKey: Self.builderFeeApprovedKey) ?? []
        guard !done.contains(addr) else {
            print("[builder] ⏭ Already approved for \(String(addr.prefix(10)))")
            return
        }

        let builderAddr = HyperliquidAPI.builderAddress
        // maxFeeRate as percent string: 1 bps = 0.01%, our builderFeeBps is typically 1 → "0.01%"
        let feePercent = String(format: "%.3f%%", Double(HyperliquidAPI.builderFeeBps) / 100.0)
        print("[builder] 🔄 Approving builder fee \(feePercent) for \(builderAddr) on \(String(addr.prefix(10)))...")

        do {
            let payload = try await TransactionSigner.signApproveBuilderFee(
                builder: builderAddr,
                maxFeeRate: feePercent
            )
            let result = try await TransactionSigner.postAction(payload)
            let status = result["status"] as? String ?? ""
            let response: String
            if let respStr = result["response"] as? String {
                response = respStr
            } else {
                response = String(describing: result)
            }
            print("[builder] API response: status=\(status) response=\(response)")

            if status == "ok" {
                done.append(addr)
                UserDefaults.standard.set(done, forKey: Self.builderFeeApprovedKey)
                print("[builder] ✅ Builder fee approved for \(String(addr.prefix(10)))")
            } else {
                // Clear any stale cache entry in case a previous bug cached a failure
                done.removeAll { $0 == addr }
                UserDefaults.standard.set(done, forKey: Self.builderFeeApprovedKey)
                print("[builder] ⚠️ Approval failed — status=\(status) response=\(response)")
            }
        } catch {
            print("[builder] ❌ Failed (will retry): \(error)")
        }
    }

    // MARK: - Analytics registration

    private static let analyticsURL = "https://hyperview-backend-production-075c.up.railway.app/analytics/register"

    private func registerAnalytics(address: String) {
        guard let url = URL(string: Self.analyticsURL) else { return }
        // Get alias if available
        let aliases = UserDefaults.standard.dictionary(forKey: "customWalletAliases") as? [String: String] ?? [:]
        let alias = aliases[address.lowercased()]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = ["address": address, "platform": "ios"]
        if let alias { body["alias"] = alias }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // Fire and forget — don't block UI
        URLSession.shared.dataTask(with: request).resume()
    }

    private func tierFor(hypeStaked: Double) -> StakingTier {
        if hypeStaked >= 500_000 { return .tier6 }
        if hypeStaked >= 100_000 { return .tier5 }
        if hypeStaked >= 10_000  { return .tier4 }
        if hypeStaked >= 1_000   { return .tier3 }
        if hypeStaked >= 100     { return .tier2 }
        if hypeStaked >= 10      { return .tier1 }
        return .none
    }
}
