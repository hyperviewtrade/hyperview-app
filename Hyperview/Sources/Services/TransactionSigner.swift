import Foundation
import libsecp256k1

// MARK: - TransactionSigner
// EIP-712 signing for Hyperliquid exchange actions (withdraw3, usdSend, spotSend).
// Uses the local secp256k1 key stored in Keychain, gated by Face ID.

@MainActor
struct TransactionSigner {

    // MARK: - Public API

    /// Sign a withdraw3 action (USDC from L1 → Arbitrum).
    static func signWithdraw3(
        destination: String,
        amount: String
    ) async throws -> [String: Any] {
        let (privKey, nonce) = try await authenticate()
        let action: [String: Any] = [
            "type": "withdraw3",
            "hyperliquidChain": "Arbitrum",
            "signatureChainId": "0x66eee",
            "destination": destination,
            "amount": amount,
            "time": nonce
        ]
        let connId = hashWithdrawAction(destination: destination, amount: amount, time: UInt64(nonce))
        let sig = try signEIP712(connectionId: connId, privateKey: privKey)
        return buildPayload(action: action, nonce: nonce, signature: sig)
    }

    /// Sign a usdSend action (internal USDC transfer).
    static func signUsdSend(
        destination: String,
        amount: String
    ) async throws -> [String: Any] {
        let (privKey, nonce) = try await authenticate()
        let action: [String: Any] = [
            "type": "usdSend",
            "hyperliquidChain": "Arbitrum",
            "signatureChainId": "0x66eee",
            "destination": destination,
            "amount": amount,
            "time": nonce
        ]
        let connId = hashWithdrawAction(destination: destination, amount: amount, time: UInt64(nonce))
        let sig = try signEIP712(connectionId: connId, privateKey: privKey)
        return buildPayload(action: action, nonce: nonce, signature: sig)
    }

    /// Sign a spotSend action (spot token transfer — bridge, send, Core→EVM).
    /// Uses EIP-712 user-signed action (NOT phantom agent).
    /// Domain: "HyperliquidSignTransaction", chainId: 421614 (0x66eee)
    /// Primary type: "HyperliquidTransaction:SpotSend"
    static func signSpotSend(
        destination: String,
        token: String,
        amount: String
    ) async throws -> [String: Any] {
        let (privKey, nonce) = try await authenticate()
        let action: [String: Any] = [
            "type": "spotSend",
            "hyperliquidChain": "Mainnet",
            "signatureChainId": "0x66eee",
            "destination": destination,
            "token": token,
            "amount": amount,
            "time": nonce
        ]

        // EIP-712 typed data signing for spotSend (user-signed action)
        let sig = try signSpotSendEIP712(
            hyperliquidChain: "Mainnet",
            destination: destination,
            token: token,
            amount: amount,
            time: UInt64(nonce),
            privateKey: privKey
        )
        return buildPayload(action: action, nonce: nonce, signature: sig)
    }

    /// EIP-712 signing for spotSend — signs action fields directly (no phantom agent).
    private static func signSpotSendEIP712(
        hyperliquidChain: String,
        destination: String,
        token: String,
        amount: String,
        time: UInt64,
        privateKey: Data
    ) throws -> [String: Any] {
        // 1. Domain separator: "HyperliquidSignTransaction", version "1", chainId 421614
        let domainTypeHash = Keccak256.hash(data: Data(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".utf8
        ))
        var domainData = Data()
        domainData.append(domainTypeHash)
        domainData.append(Keccak256.hash(data: Data("HyperliquidSignTransaction".utf8)))
        domainData.append(Keccak256.hash(data: Data("1".utf8)))
        domainData.append(padLeft(uint64BE(421614), to: 32))  // 0x66eee
        domainData.append(Data(repeating: 0, count: 32))       // verifyingContract = address(0)
        let domainSep = Keccak256.hash(data: domainData)

        // 2. SpotSend type hash
        let spotSendTypeHash = Keccak256.hash(data: Data(
            "HyperliquidTransaction:SpotSend(string hyperliquidChain,string destination,string token,string amount,uint64 time)".utf8
        ))

        // 3. Struct hash
        var structData = Data()
        structData.append(spotSendTypeHash)
        structData.append(Keccak256.hash(data: Data(hyperliquidChain.utf8)))
        structData.append(Keccak256.hash(data: Data(destination.utf8)))
        structData.append(Keccak256.hash(data: Data(token.utf8)))
        structData.append(Keccak256.hash(data: Data(amount.utf8)))
        structData.append(padLeft(uint64BE(time), to: 32))
        let structHash = Keccak256.hash(data: structData)

        // 4. EIP-712 digest
        var digest = Data([0x19, 0x01])
        digest.append(domainSep)
        digest.append(structHash)
        let finalHash = Keccak256.hash(data: digest)

        // 5. ECDSA sign
        let sigBytes = try ecdsaSignRecoverable(hash: finalHash, privateKey: privateKey)
        let r = "0x" + sigBytes[0..<32].map { String(format: "%02x", $0) }.joined()
        let s = "0x" + sigBytes[32..<64].map { String(format: "%02x", $0) }.joined()
        let v = Int(sigBytes[64])
        return ["r": r, "s": s, "v": v]
    }

    /// Sign a sendAsset action (transfer spot tokens between master/sub-accounts).
    /// Works in all account modes including unified/portfolio margin.
    /// fromSubAccount: source sub-account address, or "" for master.
    /// destination: target address (master or sub-account).
    static func signSendAsset(
        destination: String,
        token: String,
        amount: String,
        fromSubAccount: String
    ) async throws -> [String: Any] {
        let (privKey, nonce) = try await authenticate()
        let action: [String: Any] = [
            "type": "sendAsset",
            "hyperliquidChain": "Mainnet",
            "signatureChainId": "0x66eee",
            "destination": destination,
            "sourceDex": "spot",
            "destinationDex": "spot",
            "token": token,
            "amount": amount,
            "fromSubAccount": fromSubAccount,
            "nonce": nonce
        ]

        let sig = try signSendAssetEIP712(
            destination: destination,
            token: token,
            amount: amount,
            fromSubAccount: fromSubAccount,
            nonce: UInt64(nonce),
            privateKey: privKey
        )
        return buildPayload(action: action, nonce: nonce, signature: sig)
    }

    /// EIP-712 signing for sendAsset — user-signed action (same domain as spotSend).
    private static func signSendAssetEIP712(
        destination: String,
        token: String,
        amount: String,
        fromSubAccount: String,
        nonce: UInt64,
        privateKey: Data
    ) throws -> [String: Any] {
        // 1. Domain separator: "HyperliquidSignTransaction", version "1", chainId 421614
        let domainTypeHash = Keccak256.hash(data: Data(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".utf8
        ))
        var domainData = Data()
        domainData.append(domainTypeHash)
        domainData.append(Keccak256.hash(data: Data("HyperliquidSignTransaction".utf8)))
        domainData.append(Keccak256.hash(data: Data("1".utf8)))
        domainData.append(padLeft(uint64BE(421614), to: 32))  // 0x66eee
        domainData.append(Data(repeating: 0, count: 32))       // verifyingContract = address(0)
        let domainSep = Keccak256.hash(data: domainData)

        // 2. SendAsset type hash
        let sendAssetTypeHash = Keccak256.hash(data: Data(
            "HyperliquidTransaction:SendAsset(string hyperliquidChain,string destination,string sourceDex,string destinationDex,string token,string amount,string fromSubAccount,uint64 nonce)".utf8
        ))

        // 3. Struct hash
        var structData = Data()
        structData.append(sendAssetTypeHash)
        structData.append(Keccak256.hash(data: Data("Mainnet".utf8)))
        structData.append(Keccak256.hash(data: Data(destination.utf8)))
        structData.append(Keccak256.hash(data: Data("spot".utf8)))
        structData.append(Keccak256.hash(data: Data("spot".utf8)))
        structData.append(Keccak256.hash(data: Data(token.utf8)))
        structData.append(Keccak256.hash(data: Data(amount.utf8)))
        structData.append(Keccak256.hash(data: Data(fromSubAccount.utf8)))
        structData.append(padLeft(uint64BE(nonce), to: 32))
        let structHash = Keccak256.hash(data: structData)

        // 4. EIP-712 digest
        var digest = Data([0x19, 0x01])
        digest.append(domainSep)
        digest.append(structHash)
        let finalHash = Keccak256.hash(data: digest)

        #if DEBUG
        print("[SEND_ASSET] domainSep: \(domainSep.map { String(format: "%02x", $0) }.joined())")
        print("[SEND_ASSET] typeHash: \(sendAssetTypeHash.map { String(format: "%02x", $0) }.joined())")
        print("[SEND_ASSET] structHash: \(structHash.map { String(format: "%02x", $0) }.joined())")
        print("[SEND_ASSET] finalHash: \(finalHash.map { String(format: "%02x", $0) }.joined())")
        print("[SEND_ASSET] dest=\(destination) token=\(token) amount=\(amount) fromSub=\(fromSubAccount) nonce=\(nonce)")
        #endif

        // 5. ECDSA sign
        let sigBytes = try ecdsaSignRecoverable(hash: finalHash, privateKey: privateKey)
        let r = "0x" + sigBytes[0..<32].map { String(format: "%02x", $0) }.joined()
        let s = "0x" + sigBytes[32..<64].map { String(format: "%02x", $0) }.joined()
        let v = Int(sigBytes[64])
        return ["r": r, "s": s, "v": v]
    }

    /// Sign a usdClassTransfer action (move USDC between perp ↔ spot).
    /// Uses EIP-712 user-signed action (like spotSend), NOT phantom agent.
    /// Domain: "HyperliquidSignTransaction", chainId: 421614 (0x66eee)
    /// Primary type: "HyperliquidTransaction:UsdClassTransfer"
    static func signUsdClassTransfer(
        amount: String,
        toPerp: Bool
    ) async throws -> [String: Any] {
        let (privKey, nonce) = try await authenticate()
        let action: [String: Any] = [
            "type": "usdClassTransfer",
            "hyperliquidChain": "Mainnet",
            "signatureChainId": "0x66eee",
            "amount": amount,
            "toPerp": toPerp,
            "nonce": nonce
        ]
        let sig = try signUsdClassTransferEIP712(
            hyperliquidChain: "Mainnet",
            amount: amount,
            toPerp: toPerp,
            nonce: UInt64(nonce),
            privateKey: privKey
        )
        return buildPayload(action: action, nonce: nonce, signature: sig)
    }

    /// EIP-712 signing for usdClassTransfer — signs action fields directly (no phantom agent).
    private static func signUsdClassTransferEIP712(
        hyperliquidChain: String,
        amount: String,
        toPerp: Bool,
        nonce: UInt64,
        privateKey: Data
    ) throws -> [String: Any] {
        // 1. Domain separator: "HyperliquidSignTransaction", version "1", chainId 421614
        let domainTypeHash = Keccak256.hash(data: Data(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".utf8
        ))
        var domainData = Data()
        domainData.append(domainTypeHash)
        domainData.append(Keccak256.hash(data: Data("HyperliquidSignTransaction".utf8)))
        domainData.append(Keccak256.hash(data: Data("1".utf8)))
        domainData.append(padLeft(uint64BE(421614), to: 32))  // 0x66eee
        domainData.append(Data(repeating: 0, count: 32))       // verifyingContract = address(0)
        let domainSep = Keccak256.hash(data: domainData)

        // 2. UsdClassTransfer type hash
        let typeHash = Keccak256.hash(data: Data(
            "HyperliquidTransaction:UsdClassTransfer(string hyperliquidChain,string amount,bool toPerp,uint64 nonce)".utf8
        ))

        // 3. Struct hash
        var structData = Data()
        structData.append(typeHash)
        structData.append(Keccak256.hash(data: Data(hyperliquidChain.utf8)))
        structData.append(Keccak256.hash(data: Data(amount.utf8)))
        structData.append(padLeft(Data([toPerp ? 1 : 0]), to: 32))
        structData.append(padLeft(uint64BE(nonce), to: 32))
        let structHash = Keccak256.hash(data: structData)

        // 4. EIP-712 digest
        var digest = Data([0x19, 0x01])
        digest.append(domainSep)
        digest.append(structHash)
        let finalHash = Keccak256.hash(data: digest)

        // 5. ECDSA sign
        let sigBytes = try ecdsaSignRecoverable(hash: finalHash, privateKey: privateKey)
        let r = "0x" + sigBytes[0..<32].map { String(format: "%02x", $0) }.joined()
        let s = "0x" + sigBytes[32..<64].map { String(format: "%02x", $0) }.joined()
        let v = Int(sigBytes[64])
        return ["r": r, "s": s, "v": v]
    }

    /// Sign a tokenDelegate action (stake / unstake HYPE).
    /// Uses chainId 42161 (Arbitrum One) instead of 421614 used by withdraw/send.
    static func signTokenDelegate(
        validator: String,
        amount: String,
        isUndelegate: Bool
    ) async throws -> [String: Any] {
        let (privKey, nonce) = try await authenticate()
        let action: [String: Any] = [
            "type": "tokenDelegate",
            "hyperliquidChain": "Mainnet",
            "signatureChainId": "0xa4b1",
            "validator": validator,
            "isUndelegate": isUndelegate,
            "wei": amount,
            "nonce": nonce
        ]
        let connId = hashTokenDelegateAction(
            validator: validator,
            isUndelegate: isUndelegate,
            wei: amount,
            nonce: UInt64(nonce)
        )
        let sig = try signEIP712WithChainId(
            connectionId: connId,
            privateKey: privKey,
            chainId: 42161
        )
        return buildPayload(action: action, nonce: nonce, signature: sig)
    }

    // MARK: - Approve Builder Fee

    /// Sign and post approveBuilderFee. Non-financial, no biometric.
    /// Uses EIP-712 user-signed action (like spotSend): domain "HyperliquidSignTransaction", chainId 421614.
    static func signApproveBuilderFee(
        builder: String,
        maxFeeRate: String
    ) async throws -> [String: Any] {
        guard let privKey = WalletManager.shared.loadPrivateKey() else {
            throw SignerError.noPrivateKey
        }
        let nonce = Int64(Date().timeIntervalSince1970 * 1000)
        let action: [String: Any] = [
            "type": "approveBuilderFee",
            "hyperliquidChain": "Mainnet",
            "signatureChainId": "0x66eee",
            "maxFeeRate": maxFeeRate,
            "builder": builder,
            "nonce": nonce
        ]

        // EIP-712 type: HyperliquidTransaction:ApproveBuilderFee
        // Fields: hyperliquidChain (string), maxFeeRate (string), builder (address), nonce (uint64)
        let typeStr = "HyperliquidTransaction:ApproveBuilderFee(string hyperliquidChain,string maxFeeRate,address builder,uint64 nonce)"
        let typeHash = Keccak256.hash(data: Data(typeStr.utf8))

        // Domain separator: "HyperliquidSignTransaction", version "1", chainId 421614
        let domainTypeH = Keccak256.hash(data: Data(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".utf8
        ))
        var domainData = Data()
        domainData.append(domainTypeH)
        domainData.append(Keccak256.hash(data: Data("HyperliquidSignTransaction".utf8)))
        domainData.append(Keccak256.hash(data: Data("1".utf8)))
        domainData.append(padLeft(uint64BE(421614), to: 32))
        domainData.append(Data(repeating: 0, count: 32))
        let domainSep = Keccak256.hash(data: domainData)

        // Struct hash
        var structData = Data()
        structData.append(typeHash)
        structData.append(Keccak256.hash(data: Data("Mainnet".utf8)))       // hyperliquidChain
        structData.append(Keccak256.hash(data: Data(maxFeeRate.utf8)))      // maxFeeRate
        // builder is address type: left-pad 20-byte address to 32 bytes (no keccak)
        let builderClean = builder.hasPrefix("0x") ? String(builder.dropFirst(2)) : builder
        var builderBytes = Data(repeating: 0, count: 12)
        for i in stride(from: 0, to: builderClean.count, by: 2) {
            let start = builderClean.index(builderClean.startIndex, offsetBy: i)
            let end = builderClean.index(start, offsetBy: min(2, builderClean.count - i))
            if let byte = UInt8(builderClean[start..<end], radix: 16) {
                builderBytes.append(byte)
            }
        }
        structData.append(builderBytes)
        structData.append(padLeft(uint64BE(UInt64(nonce)), to: 32))         // nonce
        let structHash = Keccak256.hash(data: structData)

        // EIP-712 digest
        var digest = Data([0x19, 0x01])
        digest.append(domainSep)
        digest.append(structHash)
        let finalHash = Keccak256.hash(data: digest)

        let sigBytes = try ecdsaSignRecoverable(hash: finalHash, privateKey: privKey)
        let r = "0x" + sigBytes[0..<32].map { String(format: "%02x", $0) }.joined()
        let s = "0x" + sigBytes[32..<64].map { String(format: "%02x", $0) }.joined()
        let v = Int(sigBytes[64])
        let sig: [String: Any] = ["r": r, "s": s, "v": v]

        return buildPayload(action: action, nonce: nonce, signature: sig)
    }

    /// Sign a setReferrer action (non-financial, no biometric required).
    /// Called silently on first wallet connect.
    /// Uses msgpack-based action hashing + phantom agent EIP-712 signing (like orders).
    static func signSetReferrer(code: String) async throws -> [String: Any] {
        // Use private key directly without biometric — non-financial action
        guard let privKey = WalletManager.shared.loadPrivateKey() else {
            throw SignerError.noPrivateKey
        }
        let nonce = Int64(Date().timeIntervalSince1970 * 1000)
        let action: [String: Any] = [
            "type": "setReferrer",
            "code": code
        ]

        // Hash via msgpack — matches Python SDK's action_hash()
        // action_hash = keccak256(msgpack(action) + nonce_bytes(8) + vault_flag(1))
        let actionPairs: [(String, MsgPackValue)] = [
            ("type", .string("setReferrer")),
            ("code", .string(code))
        ]
        let actionValue = MsgPackValue.orderedMap(actionPairs)
        var data = MsgPackEncoder.encode(actionValue)
        data.append(uint64BE(UInt64(nonce)))
        data.append(0x00) // no vault
        let connId = Keccak256.hash(data: data)

        // L1 actions use chainId 1337 in the EIP-712 domain (like orders/TWAP)
        let sig = try signEIP712WithChainId(connectionId: connId, privateKey: privKey, chainId: 1337)
        return buildPayload(action: action, nonce: nonce, signature: sig)
    }

    /// Sign a createSubAccount action.
    static func signCreateSubAccount(name: String) async throws -> [String: Any] {
        let (privKey, nonce) = try await authenticate()
        let action: [String: Any] = [
            "type": "createSubAccount",
            "name": name
        ]
        let actionPairs: [(String, MsgPackValue)] = [
            ("type", .string("createSubAccount")),
            ("name", .string(name))
        ]
        let actionValue = MsgPackValue.orderedMap(actionPairs)
        var data = MsgPackEncoder.encode(actionValue)
        data.append(uint64BE(UInt64(nonce)))
        data.append(0x00)
        let connId = Keccak256.hash(data: data)
        let sig = try signEIP712WithChainId(connectionId: connId, privateKey: privKey, chainId: 1337)
        return buildPayload(action: action, nonce: nonce, signature: sig)
    }

    /// Sign a subAccountTransfer action (transfer USDC between master and sub-account).
    static func signSubAccountTransfer(subAccountUser: String, isDeposit: Bool, usd: Int) async throws -> [String: Any] {
        let (privKey, nonce) = try await authenticate()
        let action: [String: Any] = [
            "type": "subAccountTransfer",
            "subAccountUser": subAccountUser,
            "isDeposit": isDeposit,
            "usd": usd
        ]
        let actionPairs: [(String, MsgPackValue)] = [
            ("type", .string("subAccountTransfer")),
            ("subAccountUser", .string(subAccountUser)),
            ("isDeposit", .bool(isDeposit)),
            ("usd", .int(usd))
        ]
        let actionValue = MsgPackValue.orderedMap(actionPairs)
        var data = MsgPackEncoder.encode(actionValue)
        data.append(uint64BE(UInt64(nonce)))
        data.append(0x00)
        let connId = Keccak256.hash(data: data)
        let sig = try signEIP712WithChainId(connectionId: connId, privateKey: privKey, chainId: 1337)
        return buildPayload(action: action, nonce: nonce, signature: sig)
    }

    /// Sign a subAccountSpotTransfer action (transfer spot tokens between master and sub-account).
    /// isDeposit: true = master→sub, false = sub→master.
    /// token: spot token name (e.g. "HYPE", "PURR").
    /// amount: string amount (e.g. "1.5").
    static func signSubAccountSpotTransfer(subAccountUser: String, isDeposit: Bool, token: String, amount: String) async throws -> [String: Any] {
        let (privKey, nonce) = try await authenticate()
        let action: [String: Any] = [
            "type": "subAccountSpotTransfer",
            "subAccountUser": subAccountUser,
            "isDeposit": isDeposit,
            "token": token,
            "amount": amount
        ]
        let actionPairs: [(String, MsgPackValue)] = [
            ("type", .string("subAccountSpotTransfer")),
            ("subAccountUser", .string(subAccountUser)),
            ("isDeposit", .bool(isDeposit)),
            ("token", .string(token)),
            ("amount", .string(amount))
        ]
        let actionValue = MsgPackValue.orderedMap(actionPairs)
        var data = MsgPackEncoder.encode(actionValue)
        data.append(uint64BE(UInt64(nonce)))
        data.append(0x00)
        let connId = Keccak256.hash(data: data)
        let sig = try signEIP712WithChainId(connectionId: connId, privateKey: privKey, chainId: 1337)
        return buildPayload(action: action, nonce: nonce, signature: sig)
    }

    /// Sign an agentSetAbstraction action (change account mode: Classic/Portfolio Margin).
    /// Uses msgpack-based action hashing + phantom agent EIP-712 signing (chainId 1337).
    /// abstraction: "i" = disabled, "u" = unifiedAccount, "p" = portfolioMargin
    static func signAgentSetAbstraction(abstraction: String) async throws -> [String: Any] {
        guard let privKey = WalletManager.shared.loadPrivateKey() else {
            throw SignerError.noPrivateKey
        }
        let nonce = Int64(Date().timeIntervalSince1970 * 1000)
        let action: [String: Any] = [
            "type": "agentSetAbstraction",
            "abstraction": abstraction
        ]

        let actionPairs: [(String, MsgPackValue)] = [
            ("type", .string("agentSetAbstraction")),
            ("abstraction", .string(abstraction))
        ]
        let actionValue = MsgPackValue.orderedMap(actionPairs)
        var data = MsgPackEncoder.encode(actionValue)
        data.append(uint64BE(UInt64(nonce)))
        data.append(0x00) // no vault
        let connId = Keccak256.hash(data: data)

        let sig = try signEIP712WithChainId(
            connectionId: connId, privateKey: privKey, chainId: 1337
        )
        return buildPayload(action: action, nonce: nonce, signature: sig)
    }

    /// Sign an updateLeverage action (change leverage + margin mode per asset).
    /// Uses msgpack-based action hashing + phantom agent EIP-712 signing (chainId 1337).
    static func signUpdateLeverage(
        asset: Int,
        isCross: Bool,
        leverage: Int
    ) async throws -> [String: Any] {
        guard let privKey = WalletManager.shared.loadPrivateKey() else {
            throw SignerError.noPrivateKey
        }
        let nonce = Int64(Date().timeIntervalSince1970 * 1000)
        let vaultAddress = WalletManager.shared.activeVaultAddress

        let action: [String: Any] = [
            "type": "updateLeverage",
            "asset": asset,
            "isCross": isCross,
            "leverage": leverage
        ]

        // Msgpack hash — key order: type, asset, isCross, leverage
        let actionPairs: [(String, MsgPackValue)] = [
            ("type", .string("updateLeverage")),
            ("asset", .int(asset)),
            ("isCross", .bool(isCross)),
            ("leverage", .int(leverage))
        ]
        let actionValue = MsgPackValue.orderedMap(actionPairs)
        var data = MsgPackEncoder.encode(actionValue)
        data.append(uint64BE(UInt64(nonce)))

        // Vault support for sub-accounts (vault goes in hash + top-level payload, NOT inside action)
        if let vault = vaultAddress {
            data.append(0x01)
            let hex = vault.hasPrefix("0x") ? String(vault.dropFirst(2)) : vault
            for i in stride(from: 0, to: hex.count, by: 2) {
                let start = hex.index(hex.startIndex, offsetBy: i)
                let end = hex.index(start, offsetBy: min(2, hex.count - i))
                if let byte = UInt8(hex[start..<end], radix: 16) {
                    data.append(byte)
                }
            }
        } else {
            data.append(0x00)
        }

        let connId = Keccak256.hash(data: data)
        let sig = try signEIP712WithChainId(
            connectionId: connId, privateKey: privKey, chainId: 1337
        )
        return buildPayload(action: action, nonce: nonce, signature: sig, vaultAddress: vaultAddress)
    }

    /// Sign a borrowLend action (supply or withdraw from Earn in classic mode).
    /// operation: "supply" or "withdraw"
    /// token: token index (0=USDC, 150=HYPE, 197=UBTC, 360=USDH)
    /// amount: string amount to supply/withdraw
    static func signBorrowLend(
        operation: String,
        token: Int,
        amount: String
    ) async throws -> [String: Any] {
        // ── Input Validation ──
        guard ["supply", "withdraw"].contains(operation) else {
            throw SignerError.invalidInput("Operation must be 'supply' or 'withdraw'")
        }
        guard token >= 0 else {
            throw SignerError.invalidInput("Token index must be >= 0")
        }
        let cleanAmt = amount.replacingOccurrences(of: ",", with: ".")
        guard let amtVal = Double(cleanAmt), amtVal > 0, !amtVal.isNaN else {
            throw SignerError.invalidInput("Amount must be a positive number")
        }
        // ──────────────────────
        guard let privKey = WalletManager.shared.loadPrivateKey() else {
            throw SignerError.noPrivateKey
        }
        let nonce = Int64(Date().timeIntervalSince1970 * 1000)
        let vaultAddress = WalletManager.shared.activeVaultAddress

        let action: [String: Any] = [
            "type": "borrowLend",
            "operation": operation,
            "token": token,
            "amount": amount
        ]

        // Msgpack hash — key order: type, operation, token, amount
        let actionPairs: [(String, MsgPackValue)] = [
            ("type", .string("borrowLend")),
            ("operation", .string(operation)),
            ("token", .int(token)),
            ("amount", .string(amount))
        ]
        let actionValue = MsgPackValue.orderedMap(actionPairs)
        var data = MsgPackEncoder.encode(actionValue)
        data.append(uint64BE(UInt64(nonce)))

        // Vault support for sub-accounts
        if let vault = vaultAddress {
            data.append(0x01)
            let hex = vault.hasPrefix("0x") ? String(vault.dropFirst(2)) : vault
            for i in stride(from: 0, to: hex.count, by: 2) {
                let start = hex.index(hex.startIndex, offsetBy: i)
                let end = hex.index(start, offsetBy: min(2, hex.count - i))
                if let byte = UInt8(hex[start..<end], radix: 16) {
                    data.append(byte)
                }
            }
        } else {
            data.append(0x00)
        }

        let connId = Keccak256.hash(data: data)
        let sig = try signEIP712WithChainId(
            connectionId: connId, privateKey: privKey, chainId: 1337
        )
        return buildPayload(action: action, nonce: nonce, signature: sig, vaultAddress: vaultAddress)
    }

    /// Sign a TWAP order action.
    static func signTwapOrder(
        assetIndex: Int,
        isBuy: Bool,
        size: Double,
        reduceOnly: Bool,
        durationMinutes: Int,
        randomize: Bool,
        szDecimals: Int = 4
    ) async throws -> [String: Any] {
        let (privKey, nonce) = try await authenticate()

        let roundedSize = roundToDecimals(size, decimals: szDecimals)
        let sizeStr = floatToWire(roundedSize)

        // Build TWAP wire in exact key order
        let twapWire: [(String, Any)] = [
            ("a", assetIndex),
            ("b", isBuy),
            ("s", sizeStr),
            ("r", reduceOnly),
            ("m", durationMinutes),
            ("t", randomize)
        ]

        var twapDict: [String: Any] = [:]
        for (k, v) in twapWire { twapDict[k] = v }

        let action: [String: Any] = [
            "type": "twapOrder",
            "twap": twapDict,
            "builder": [
                "b": HyperliquidAPI.builderAddress,
                "f": HyperliquidAPI.builderFeeBps
            ] as [String: Any]
        ]

        // Msgpack hash — must include builder (Python SDK includes it in the action dict)
        let actionPairs: [(String, MsgPackValue)] = [
            ("type", .string("twapOrder")),
            ("twap", .orderedMap(twapWire.map { (k, v) in (k, anyToMsgPack(v)) })),
            ("builder", .orderedMap([
                ("b", .string(HyperliquidAPI.builderAddress.lowercased())),
                ("f", .int(HyperliquidAPI.builderFeeBps))
            ]))
        ]
        let actionValue = MsgPackValue.orderedMap(actionPairs)
        var data = MsgPackEncoder.encode(actionValue)
        data.append(uint64BE(UInt64(nonce)))
        let vault = WalletManager.shared.activeVaultAddress
        appendVaultFlag(&data, vault: vault)
        let connId = Keccak256.hash(data: data)

        let sig = try signEIP712WithChainId(connectionId: connId, privateKey: privKey, chainId: 1337)
        return buildPayload(action: action, nonce: nonce, signature: sig, vaultAddress: vault)
    }

    /// Sign a TWAP cancel action.
    static func signCancelTwap(
        assetIndex: Int,
        twapId: Int64
    ) async throws -> [String: Any] {
        let (privKey, nonce) = try await authenticate()

        let cancelWire: [(String, Any)] = [
            ("a", assetIndex),
            ("t", twapId)
        ]

        var cancelDict: [String: Any] = [:]
        for (k, v) in cancelWire { cancelDict[k] = v }

        let action: [String: Any] = [
            "type": "twapCancel",
            "a": assetIndex,
            "t": twapId
        ]

        let actionPairs: [(String, MsgPackValue)] = [
            ("type", .string("twapCancel")),
            ("a", .int(assetIndex)),
            ("t", .int(Int(twapId)))
        ]
        let actionValue = MsgPackValue.orderedMap(actionPairs)
        var data = MsgPackEncoder.encode(actionValue)
        data.append(uint64BE(UInt64(nonce)))
        let vault = WalletManager.shared.activeVaultAddress
        appendVaultFlag(&data, vault: vault)
        let connId = Keccak256.hash(data: data)

        let sig = try signEIP712WithChainId(connectionId: connId, privateKey: privKey, chainId: 1337)
        return buildPayload(action: action, nonce: nonce, signature: sig, vaultAddress: vault)
    }

    /// Sign a cancel order action.
    /// Uses msgpack-based action hashing + phantom agent EIP-712 signing (chainId 1337).
    static func signCancelOrder(
        assetIndex: Int,
        oid: Int64
    ) async throws -> [String: Any] {
        let (privKey, nonce) = try await authenticate()

        let cancelWire: [(String, Any)] = [
            ("a", assetIndex),
            ("o", oid)
        ]

        var cancelDict: [String: Any] = [:]
        for (k, v) in cancelWire { cancelDict[k] = v }

        let action: [String: Any] = [
            "type": "cancel",
            "cancels": [cancelDict]
        ]

        // Build msgpack for cancel action
        let actionPairs: [(String, MsgPackValue)] = [
            ("type", .string("cancel")),
            ("cancels", .array([
                .orderedMap(cancelWire.map { (k, v) in (k, anyToMsgPack(v)) })
            ]))
        ]
        let actionValue = MsgPackValue.orderedMap(actionPairs)
        var data = MsgPackEncoder.encode(actionValue)
        data.append(uint64BE(UInt64(nonce)))
        let vault = WalletManager.shared.activeVaultAddress
        appendVaultFlag(&data, vault: vault)
        let connId = Keccak256.hash(data: data)

        let sig = try signEIP712WithChainId(connectionId: connId, privateKey: privKey, chainId: 1337)
        return buildPayload(action: action, nonce: nonce, signature: sig, vaultAddress: vault)
    }

    /// Sign an order action (place perp or spot order on Hyperliquid).
    /// Uses msgpack-based action hashing + phantom agent EIP-712 signing (chainId 1337).
    static func signOrder(
        assetIndex: Int,
        isBuy: Bool,
        limitPrice: Double,
        size: Double,
        reduceOnly: Bool,
        orderType: [String: Any],   // {"limit": {"tif": "Gtc"}} or {"limit": {"tif": "Ioc"}}
        szDecimals: Int = 4,
        cloid: String? = nil,
        roundUp: Bool = false
    ) async throws -> [String: Any] {

        // ── Input Validation ──────────────────────────────────────
        guard assetIndex >= 0 else {
            throw SignerError.invalidInput("Asset index must be >= 0")
        }
        guard limitPrice > 0, !limitPrice.isNaN, !limitPrice.isInfinite else {
            throw SignerError.invalidInput("Price must be positive and finite")
        }
        guard size > 0, !size.isNaN, !size.isInfinite else {
            throw SignerError.invalidInput("Size must be positive and finite")
        }
        guard szDecimals >= 0, szDecimals <= 8 else {
            throw SignerError.invalidInput("szDecimals must be 0-8")
        }
        // ──────────────────────────────────────────────────────────

        let (privKey, nonce) = try await authenticate()

        // Price: round to 5 significant figures then to appropriate decimal places
        // Matches Python SDK: round(float(f"{px:.5g}"), max_decimals)
        // Spot assets: index 10000-99999 → max 8 decimals
        // Perp assets: index 0-9999 (main) or 100000+ (HIP-3) → max 6 decimals
        let isSpot = assetIndex >= 10000 && assetIndex < 100000
        let maxPriceDecimals = (isSpot ? 8 : 6) - szDecimals
        let roundedPrice = roundToSigFigs(limitPrice, sigFigs: 5, maxDecimals: maxPriceDecimals)
        let priceStr = floatToWire(roundedPrice)

        // Size: truncate to szDecimals, or round up for full close (avoid falling below HL $10 min)
        let roundedSize: Double
        if roundUp {
            let factor = pow(10.0, Double(szDecimals))
            roundedSize = ceil(size * factor) / factor
        } else {
            roundedSize = roundToDecimals(size, decimals: szDecimals)
        }
        let sizeStr  = floatToWire(roundedSize)

        // Build order wire in EXACT key order matching Python SDK
        var orderWire: [(String, Any)] = [
            ("a", assetIndex),
            ("b", isBuy),
            ("p", priceStr),
            ("s", sizeStr),
            ("r", reduceOnly),
            ("t", orderType)
        ]
        if let cloid = cloid { orderWire.append(("c", cloid)) }

        // Build the action dict for JSON (unordered is fine for JSON)
        var orderDict: [String: Any] = [:]
        for (k, v) in orderWire { orderDict[k] = v }

        let action: [String: Any] = [
            "type": "order",
            "orders": [orderDict],
            "grouping": "na",
            "builder": [
                "b": HyperliquidAPI.builderAddress,
                "f": HyperliquidAPI.builderFeeBps
            ] as [String: Any]
        ]

        // Hash via msgpack (NOT ABI encoding) — matches Python SDK action_hash()
        let vault = WalletManager.shared.activeVaultAddress
        let connId = hashOrderActionMsgpack(
            orderWires: orderWire,
            grouping: "na",
            nonce: UInt64(nonce),
            vaultAddress: vault,
            builder: (address: HyperliquidAPI.builderAddress.lowercased(), feeBps: HyperliquidAPI.builderFeeBps)
        )

        #if DEBUG
        print("[ORDER] asset=\(assetIndex) buy=\(isBuy) price=\(priceStr) size=\(sizeStr) vault=\(vault ?? "none") nonce=\(nonce)")
        print("[ORDER] connId=\(connId.map { String(format: "%02x", $0) }.joined())")
        #endif

        // Sign with chainId 1337 (Hyperliquid L1 exchange — hardcoded in Python SDK)
        let sig = try signEIP712WithChainId(connectionId: connId, privateKey: privKey, chainId: 1337)
        return buildPayload(action: action, nonce: nonce, signature: sig, vaultAddress: vault)
    }

    /// Round a value DOWN to a given number of decimal places (truncate — never exceed balance).
    private static func roundToDecimals(_ value: Double, decimals: Int) -> Double {
        let factor = pow(10.0, Double(decimals))
        return floor(value * factor) / factor
    }

    /// Round to N significant figures, then cap at maxDecimals.
    /// Matches Python SDK: round(float(f"{px:.5g}"), maxDecimals)
    private static func roundToSigFigs(_ value: Double, sigFigs: Int, maxDecimals: Int) -> Double {
        guard value != 0 else { return 0 }
        // Step 1: round to sigFigs significant figures (like Python's f"{px:.5g}")
        let d = ceil(log10(abs(value)))
        let power = sigFigs - Int(d)
        let magnitude = pow(10.0, Double(power))
        let shifted = (value * magnitude).rounded()
        let sigRounded = shifted / magnitude
        // Step 2: round to maxDecimals decimal places
        let decFactor = pow(10.0, Double(max(0, maxDecimals)))
        return (sigRounded * decFactor).rounded() / decFactor
    }

    /// Python SDK's float_to_wire: format to 8 decimals, normalize via Decimal (strip trailing zeros).
    /// "100.50000000" → "100.5", "0.01000000" → "0.01", "100.00000000" → "100"
    static func floatToWire(_ x: Double) -> String {
        let raw = String(format: "%.8f", x)
        // Strip trailing zeros after decimal point
        guard raw.contains(".") else { return raw }
        var result = raw
        while result.hasSuffix("0") { result.removeLast() }
        if result.hasSuffix(".") { result.removeLast() }
        return result
    }

    /// Post a signed payload to /exchange.
    static func postAction(_ payload: [String: Any]) async throws -> [String: Any] {
        let data = try await HyperliquidAPI.shared.post(
            url: URL(string: "https://api.hyperliquid.xyz/exchange")!,
            body: payload
        )
        if let raw = String(data: data, encoding: .utf8) {
            #if DEBUG
            print("[EXCHANGE] Response: \(raw)")
            #endif
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Constants

    /// EIP-712 domain separator chainId — Hyperliquid uses 421614 even on mainnet
    private static let domainChainId: UInt64 = 421614
    /// Action hash chainId — Arbitrum One mainnet
    private static let actionChainId: UInt64 = 42161
    /// Action hash Hyperliquid chain enum — 1 = Mainnet
    private static let hlChainId: UInt8 = 1
    private static let source = "a"                       // mainnet

    // Pre-computed type hashes (keccak256 of the type string)
    private static let domainTypeHash = Keccak256.hash(data: Data(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".utf8
    ))
    private static let agentTypeHash = Keccak256.hash(data: Data(
        "Agent(string source,bytes32 connectionId)".utf8
    ))

    // Domain separator (constant — same for every phantom agent signature)
    // Uses domainChainId=421614 (Hyperliquid convention, even on mainnet)
    private static let domainSeparator: Data = {
        var d = Data()
        d.append(domainTypeHash)
        d.append(Keccak256.hash(data: Data("Exchange".utf8)))
        d.append(Keccak256.hash(data: Data("1".utf8)))
        d.append(padLeft(uint64BE(domainChainId), to: 32))
        d.append(Data(repeating: 0, count: 32))   // verifyingContract = address(0)
        return Keccak256.hash(data: d)
    }()

    // MARK: - Authentication

    private static func authenticate() async throws -> (privateKey: Data, nonce: Int64) {
        let wallet = WalletManager.shared
        guard await wallet.authenticateForTransaction() else {
            throw SignerError.biometricFailed
        }
        guard let pk = wallet.loadPrivateKey() else {
            throw SignerError.noPrivateKey
        }
        return (pk, Int64(Date().timeIntervalSince1970 * 1000))
    }

    // MARK: - Action hashes

    private static func hashWithdrawAction(destination: String, amount: String, time: UInt64) -> Data {
        // ABI encode: (uint8, uint64, string, string, uint64)
        let encoded = abiEncode([
            .uint8(1),              // hlChainId = 1 for Mainnet
            .uint64(42161),         // Arbitrum One chainId
            .string(destination),
            .string(amount),
            .uint64(time)
        ])
        return Keccak256.hash(data: encoded)
    }

    private static func hashSpotSendAction(destination: String, token: String,
                                            amount: String, time: UInt64) -> Data {
        let encoded = abiEncode([
            .uint8(1),              // hlChainId = 1 for Mainnet
            .uint64(42161),         // Arbitrum One chainId
            .string(destination),
            .string(token),
            .string(amount),
            .uint64(time)
        ])
        return Keccak256.hash(data: encoded)
    }

    /// Hash for tokenDelegate action (stake / unstake HYPE).
    /// ABI encode: (uint8, uint64, string, bool, string, uint64)
    /// hlChainId = 1 (Mainnet) — NOT the class constant 2 (Arbitrum).
    private static func hashTokenDelegateAction(
        validator: String,
        isUndelegate: Bool,
        wei: String,
        nonce: UInt64
    ) -> Data {
        let encoded = abiEncode([
            .uint8(1),              // hlChainId = 1 for Mainnet
            .uint64(42161),
            .string(validator),
            .bool(isUndelegate),
            .string(wei),
            .uint64(nonce)
        ])
        return Keccak256.hash(data: encoded)
    }

    /// Hash for usdClassTransfer action (perp ↔ spot USDC transfer).
    /// ABI encode: (uint8, uint64, string, bool, uint64)
    /// hlChainId = 1 (Mainnet) — NOT the class constant 2 (Arbitrum).
    private static func hashUsdClassTransferAction(
        amount: String,
        toPerp: Bool,
        nonce: UInt64
    ) -> Data {
        let encoded = abiEncode([
            .uint8(1),              // hlChainId = 1 for Mainnet
            .uint64(42161),
            .string(amount),
            .bool(toPerp),
            .uint64(nonce)
        ])
        return Keccak256.hash(data: encoded)
    }

    /// Hash order action using msgpack — matches Python SDK's action_hash().
    /// action_hash = keccak256(msgpack(action) + nonce_bytes(8) + vault_flag(1))
    private static func hashOrderActionMsgpack(
        orderWires: [(String, Any)],
        grouping: String,
        nonce: UInt64,
        vaultAddress: String?,
        builder: (address: String, feeBps: Int)? = nil
    ) -> Data {
        // Build the action as ordered msgpack
        // Key order must match Python SDK: "type", "orders", "grouping", "builder"
        var actionPairs: [(String, MsgPackValue)] = [
            ("type", .string("order")),
            ("orders", .array([
                .orderedMap(orderWires.map { (k, v) in
                    (k, anyToMsgPack(v))
                })
            ])),
            ("grouping", .string(grouping))
        ]
        // Builder must be included in the hash (Python SDK includes it in the action dict)
        if let builder = builder {
            actionPairs.append(("builder", .orderedMap([
                ("b", .string(builder.address)),
                ("f", .int(builder.feeBps))
            ])))
        }

        let actionValue = MsgPackValue.orderedMap(actionPairs)
        var data = MsgPackEncoder.encode(actionValue)

        // Append nonce as 8-byte big-endian
        data.append(uint64BE(nonce))

        // Append vault flag
        if let vault = vaultAddress {
            data.append(0x01)
            // Convert hex address to 20 bytes
            let hex = vault.hasPrefix("0x") ? String(vault.dropFirst(2)) : vault
            for i in stride(from: 0, to: hex.count, by: 2) {
                let start = hex.index(hex.startIndex, offsetBy: i)
                let end = hex.index(start, offsetBy: min(2, hex.count - i))
                if let byte = UInt8(hex[start..<end], radix: 16) {
                    data.append(byte)
                }
            }
        } else {
            data.append(0x00)
        }

        return Keccak256.hash(data: data)
    }

    /// Convert Any to MsgPackValue (for order wire fields).
    /// Note: Bool must be checked before Int since Swift treats Bool as Int-convertible.
    private static func anyToMsgPack(_ value: Any) -> MsgPackValue {
        // Check Bool BEFORE Int (Swift Bool conforms to Int-like protocols)
        if let b = value as? Bool { return .bool(b) }
        if let s = value as? String { return .string(s) }
        if let i = value as? Int { return .int(i) }
        if let i64 = value as? Int64 { return .int(Int(i64)) }
        if let d = value as? [String: Any] {
            // Sort keys alphabetically for deterministic output (single-key dicts don't need it
            // but multi-key dicts must be consistent)
            let sorted = d.sorted { $0.key < $1.key }
            let pairs = sorted.map { (k, v) in (k, anyToMsgPack(v)) }
            return .orderedMap(pairs)
        }
        if let arr = value as? [Any] {
            return .array(arr.map { anyToMsgPack($0) })
        }
        return .nil_
    }

    private static func hashSetReferrerAction(code: String, nonce: UInt64) -> Data {
        let encoded = abiEncode([
            .uint8(1),              // hlChainId = 1 for Mainnet
            .uint64(42161),         // Arbitrum One chainId
            .string(code),
            .uint64(nonce)
        ])
        return Keccak256.hash(data: encoded)
    }

    // MARK: - EIP-712 signing

    /// Compute a domain separator for a given chainId (reusable).
    private static func domainSeparator(forChainId cId: UInt64) -> Data {
        var d = Data()
        d.append(domainTypeHash)
        d.append(Keccak256.hash(data: Data("Exchange".utf8)))
        d.append(Keccak256.hash(data: Data("1".utf8)))
        d.append(padLeft(uint64BE(cId), to: 32))
        d.append(Data(repeating: 0, count: 32))   // verifyingContract = address(0)
        return Keccak256.hash(data: d)
    }

    /// EIP-712 signing with a specific chainId (used for tokenDelegate on Arbitrum One 42161).
    private static func signEIP712WithChainId(connectionId: Data, privateKey: Data,
                                               chainId cId: UInt64) throws -> [String: Any] {
        var agentData = Data()
        agentData.append(agentTypeHash)
        agentData.append(Keccak256.hash(data: Data(source.utf8)))
        agentData.append(connectionId)
        let agentHash = Keccak256.hash(data: agentData)

        var digest = Data([0x19, 0x01])
        digest.append(domainSeparator(forChainId: cId))
        digest.append(agentHash)
        let finalHash = Keccak256.hash(data: digest)

        let sigBytes = try ecdsaSignRecoverable(hash: finalHash, privateKey: privateKey)

        let r = "0x" + sigBytes[0..<32].map { String(format: "%02x", $0) }.joined()
        let s = "0x" + sigBytes[32..<64].map { String(format: "%02x", $0) }.joined()
        let v = Int(sigBytes[64])
        return ["r": r, "s": s, "v": v]
    }

    private static func signEIP712(connectionId: Data, privateKey: Data) throws -> [String: Any] {
        // 1. Agent struct hash
        var agentData = Data()
        agentData.append(agentTypeHash)
        agentData.append(Keccak256.hash(data: Data(source.utf8)))
        agentData.append(connectionId)
        let agentHash = Keccak256.hash(data: agentData)

        // 2. EIP-712 digest: keccak256(0x19 0x01 ‖ domainSeparator ‖ agentHash)
        var digest = Data([0x19, 0x01])
        digest.append(domainSeparator)
        digest.append(agentHash)
        let finalHash = Keccak256.hash(data: digest)

        // 3. ECDSA recoverable signature via libsecp256k1 C API
        let sigBytes = try ecdsaSignRecoverable(hash: finalHash, privateKey: privateKey)

        // 4. Format for Hyperliquid API: { r, s, v }
        let r = "0x" + sigBytes[0..<32].map { String(format: "%02x", $0) }.joined()
        let s = "0x" + sigBytes[32..<64].map { String(format: "%02x", $0) }.joined()
        let v = Int(sigBytes[64])
        return ["r": r, "s": s, "v": v]
    }

    /// Recoverable ECDSA over a 32-byte keccak256 hash.
    /// Returns 65 bytes: r(32) ‖ s(32) ‖ v(1), v ∈ {27, 28}.
    static func ecdsaSignRecoverable(hash: Data, privateKey: Data) throws -> Data {
        let hashBytes = [UInt8](hash)
        let keyBytes  = [UInt8](privateKey)
        guard hashBytes.count == 32, keyBytes.count == 32 else {
            throw SignerError.signingFailed("invalid input lengths")
        }

        // libsecp256k1 C API — compiled as part of secp256k1.swift SPM package
        // C macros aren't importable in Swift; SECP256K1_CONTEXT_NONE = 1
        guard let ctx = secp256k1_context_create(UInt32(1)) else {
            throw SignerError.signingFailed("secp256k1_context_create returned nil")
        }
        defer { secp256k1_context_destroy(ctx) }

        var sig = secp256k1_ecdsa_recoverable_signature()
        guard secp256k1_ecdsa_sign_recoverable(ctx, &sig, hashBytes, keyBytes, nil, nil) == 1 else {
            throw SignerError.signingFailed("secp256k1_ecdsa_sign_recoverable failed")
        }

        var compact = [UInt8](repeating: 0, count: 64)
        var recid: Int32 = 0
        secp256k1_ecdsa_recoverable_signature_serialize_compact(ctx, &compact, &recid, &sig)

        var result = Data(compact)             // r(32) + s(32)
        result.append(UInt8(recid) + 27)       // v = recid + 27
        return result
    }

    /// Append vault flag bytes to msgpack data for action hashing
    private static func appendVaultFlag(_ data: inout Data, vault: String?) {
        if let v = vault {
            let hex = v.hasPrefix("0x") ? String(v.dropFirst(2)) : v
            // Validate: must be exactly 40 hex characters (20 bytes)
            guard hex.count == 40, hex.allSatisfy({ $0.isHexDigit }) else {
                print("⚠️ Invalid vault address: \(v) — using no-vault flag")
                data.append(0x00)
                return
            }
            data.append(0x01)
            for i in stride(from: 0, to: 40, by: 2) {
                let start = hex.index(hex.startIndex, offsetBy: i)
                let end = hex.index(start, offsetBy: 2)
                data.append(UInt8(hex[start..<end], radix: 16)!)
            }
        } else {
            data.append(0x00)
        }
    }

    // MARK: - Payload builder

    private static func buildPayload(action: [String: Any], nonce: Int64,
                                      signature: [String: Any],
                                      vaultAddress: String? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "action": action,
            "nonce": nonce,
            "signature": signature
        ]
        if let vault = vaultAddress {
            payload["vaultAddress"] = vault
        }
        return payload
    }

    // MARK: - ABI encoder (minimal, for EIP-712 action hashing)

    private enum ABIValue {
        case uint8(UInt8)
        case uint64(UInt64)
        case string(String)
        case bool(Bool)
    }

    /// Standard Solidity ABI encoding for a tuple (handles dynamic string types).
    private static func abiEncode(_ values: [ABIValue]) -> Data {
        var head = Data()
        var tail = Data()
        let headSize = values.count * 32

        for value in values {
            switch value {
            case .uint8(let v):
                head.append(padLeft(Data([v]), to: 32))
            case .uint64(let v):
                head.append(padLeft(uint64BE(v), to: 32))
            case .bool(let b):
                head.append(padLeft(Data([b ? 1 : 0]), to: 32))
            case .string(let s):
                let offset = UInt64(headSize + tail.count)
                head.append(padLeft(uint64BE(offset), to: 32))
                let bytes = Data(s.utf8)
                tail.append(padLeft(uint64BE(UInt64(bytes.count)), to: 32))
                tail.append(bytes)
                let rem = bytes.count % 32
                if rem != 0 { tail.append(Data(repeating: 0, count: 32 - rem)) }
            }
        }
        return head + tail
    }

    static func uint64BE(_ v: UInt64) -> Data {
        withUnsafeBytes(of: v.bigEndian) { Data($0) }
    }

    static func padLeft(_ data: Data, to size: Int) -> Data {
        guard data.count < size else { return Data(data.prefix(size)) }
        return Data(repeating: 0, count: size - data.count) + data
    }
}

// MARK: - Minimal MsgPack Encoder (for Hyperliquid action hashing)

/// Represents a msgpack value. Uses orderedMap to preserve key insertion order.
enum MsgPackValue {
    case nil_
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([MsgPackValue])
    case orderedMap([(String, MsgPackValue)])
}

/// Minimal msgpack encoder supporting the types used by Hyperliquid order actions.
enum MsgPackEncoder {
    static func encode(_ value: MsgPackValue) -> Data {
        var data = Data()
        encode(value, into: &data)
        return data
    }

    private static func encode(_ value: MsgPackValue, into data: inout Data) {
        switch value {
        case .nil_:
            data.append(0xc0)

        case .bool(let b):
            data.append(b ? 0xc3 : 0xc2)

        case .int(let n):
            if n >= 0 && n <= 127 {
                // positive fixint
                data.append(UInt8(n))
            } else if n >= 0 && n <= 0xFF {
                // uint 8
                data.append(0xcc)
                data.append(UInt8(n))
            } else if n >= 0 && n <= 0xFFFF {
                // uint 16
                data.append(0xcd)
                data.append(UInt8((n >> 8) & 0xFF))
                data.append(UInt8(n & 0xFF))
            } else if n >= 0 && n <= 0xFFFFFFFF {
                // uint 32
                data.append(0xce)
                data.append(UInt8((n >> 24) & 0xFF))
                data.append(UInt8((n >> 16) & 0xFF))
                data.append(UInt8((n >> 8) & 0xFF))
                data.append(UInt8(n & 0xFF))
            } else if n < 0 && n >= -32 {
                // negative fixint
                data.append(UInt8(bitPattern: Int8(n)))
            } else {
                // int 64 / uint 64 fallback
                data.append(0xcf)
                let u = UInt64(bitPattern: Int64(n))
                for shift in stride(from: 56, through: 0, by: -8) {
                    data.append(UInt8((u >> shift) & 0xFF))
                }
            }

        case .string(let s):
            let bytes = Data(s.utf8)
            let len = bytes.count
            if len <= 31 {
                // fixstr
                data.append(0xa0 | UInt8(len))
            } else if len <= 0xFF {
                // str 8
                data.append(0xd9)
                data.append(UInt8(len))
            } else if len <= 0xFFFF {
                // str 16
                data.append(0xda)
                data.append(UInt8((len >> 8) & 0xFF))
                data.append(UInt8(len & 0xFF))
            } else {
                // str 32
                data.append(0xdb)
                data.append(UInt8((len >> 24) & 0xFF))
                data.append(UInt8((len >> 16) & 0xFF))
                data.append(UInt8((len >> 8) & 0xFF))
                data.append(UInt8(len & 0xFF))
            }
            data.append(bytes)

        case .array(let items):
            let count = items.count
            if count <= 15 {
                data.append(0x90 | UInt8(count))
            } else if count <= 0xFFFF {
                data.append(0xdc)
                data.append(UInt8((count >> 8) & 0xFF))
                data.append(UInt8(count & 0xFF))
            } else {
                data.append(0xdd)
                data.append(UInt8((count >> 24) & 0xFF))
                data.append(UInt8((count >> 16) & 0xFF))
                data.append(UInt8((count >> 8) & 0xFF))
                data.append(UInt8(count & 0xFF))
            }
            for item in items {
                encode(item, into: &data)
            }

        case .orderedMap(let pairs):
            let count = pairs.count
            if count <= 15 {
                data.append(0x80 | UInt8(count))
            } else if count <= 0xFFFF {
                data.append(0xde)
                data.append(UInt8((count >> 8) & 0xFF))
                data.append(UInt8(count & 0xFF))
            } else {
                data.append(0xdf)
                data.append(UInt8((count >> 24) & 0xFF))
                data.append(UInt8((count >> 16) & 0xFF))
                data.append(UInt8((count >> 8) & 0xFF))
                data.append(UInt8(count & 0xFF))
            }
            for (key, value) in pairs {
                encode(.string(key), into: &data)
                encode(value, into: &data)
            }
        }
    }
}

// MARK: - SignerError

enum SignerError: LocalizedError {
    case biometricFailed
    case noPrivateKey
    case signingFailed(String)
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .biometricFailed:      return "Biometric authentication failed"
        case .noPrivateKey:         return "Private key not found"
        case .signingFailed(let m): return "Signing failed: \(m)"
        case .invalidInput(let m):  return "Invalid input: \(m)"
        }
    }
}
