import Foundation

// MARK: - HyperEVM RPC
// JSON-RPC client for HyperEVM (Hyperliquid's EVM layer).
// Used for balance checking and Core↔EVM transfers.

final class HyperEVMRPC: Sendable {
    static let shared = HyperEVMRPC()

    static let chainId: UInt64 = 999
    static let rpcURLString = "https://rpc.hyperliquid.xyz/evm"
    /// Send native HYPE to this address to transfer from HyperEVM → HyperCore
    static let coreTransferAddress = "0x2222222222222222222222222222222222222222"

    private let rpcURL = URL(string: rpcURLString)!
    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg)
    }

    // MARK: - Generic JSON-RPC call

    func call(method: String, params: [Any]) async throws -> Any {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ]
        var req = URLRequest(url: rpcURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let msg  = error["message"] as? String ?? "Unknown RPC error"
            throw RPCError.rpcError(code: code, message: msg)
        }
        return json["result"] ?? NSNull()
    }

    // MARK: - Balance

    /// Get native HYPE balance on HyperEVM (in wei, 18 decimals)
    func getBalance(address: String) async throws -> Double {
        let result = try await call(method: "eth_getBalance", params: [address, "latest"])
        guard let hex = result as? String else { return 0 }
        return hexWeiToDouble(hex)
    }

    /// Get ERC20 token balance on HyperEVM with correct decimals
    func getERC20Balance(address: String, tokenContract: String, decimals: Int = 18) async throws -> Double {
        // balanceOf(address) selector = 0x70a08231
        let paddedAddress = "000000000000000000000000" + address.dropFirst(2)
        let calldata = "0x70a08231" + paddedAddress

        let result = try await call(method: "eth_call", params: [
            ["to": tokenContract, "data": calldata],
            "latest"
        ])
        guard let hex = result as? String else { return 0 }
        return hexToDouble(hex, decimals: decimals)
    }

    /// Convert hex value to Double using specific decimal places
    private func hexToDouble(_ hex: String, decimals: Int) -> Double {
        let cleaned = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard !cleaned.isEmpty else { return 0 }
        let divisor = pow(10.0, Double(decimals))
        if cleaned.count <= 16, let value = UInt64(cleaned, radix: 16) {
            return Double(value) / divisor
        }
        var result: Double = 0
        for char in cleaned {
            guard let digit = UInt8(String(char), radix: 16) else { return 0 }
            result = result * 16 + Double(digit)
        }
        return result / divisor
    }

    // MARK: - Transaction Helpers

    func getTransactionCount(address: String) async throws -> UInt64 {
        let result = try await call(method: "eth_getTransactionCount", params: [address, "pending"])
        guard let hex = result as? String else { throw RPCError.invalidResponse }
        return hexToUInt64(hex)
    }

    func estimateGas(tx: [String: Any]) async throws -> UInt64 {
        let result = try await call(method: "eth_estimateGas", params: [tx])
        guard let hex = result as? String else { throw RPCError.invalidResponse }
        return hexToUInt64(hex)
    }

    func getBaseFee() async throws -> UInt64 {
        let result = try await call(method: "eth_getBlockByNumber", params: ["latest", false])
        guard let block = result as? [String: Any],
              let hex = block["baseFeePerGas"] as? String else { throw RPCError.invalidResponse }
        return hexToUInt64(hex)
    }

    func getMaxPriorityFee() async throws -> UInt64 {
        let result = try await call(method: "eth_maxPriorityFeePerGas", params: [])
        guard let hex = result as? String else {
            return 100_000_000 // 0.1 gwei fallback
        }
        return hexToUInt64(hex)
    }

    func sendRawTransaction(_ signedTx: Data) async throws -> String {
        let hex = "0x" + signedTx.map { String(format: "%02x", $0) }.joined()
        let result = try await call(method: "eth_sendRawTransaction", params: [hex])
        guard let txHash = result as? String else { throw RPCError.invalidResponse }
        return txHash
    }

    // MARK: - Transfer HYPE: EVM → Core

    /// Convert a HYPE amount (Double) to wei as big-endian Data.
    /// Uses Decimal to avoid UInt64 overflow (1 HYPE = 1e18 wei).
    private func amountToWei(_ amount: Double) -> (hex: String, bytes: Data) {
        // Use string-based approach for precision: split integer and decimal parts
        let str = String(format: "%.18f", amount)
        let parts = str.components(separatedBy: ".")
        let intPart = parts[0]
        let decPart = String((parts.count > 1 ? parts[1] : "").prefix(18)).padding(toLength: 18, withPad: "0", startingAt: 0)

        // Combine: integer part + 18 decimal digits = wei as string
        let weiStr = intPart + decPart
        // Trim leading zeros
        let trimmed = String(weiStr.drop { $0 == "0" })
        guard !trimmed.isEmpty else { return ("0x0", Data()) }

        // Convert to hex
        var hexResult = ""
        var decimalValue = Decimal(string: trimmed) ?? 0
        if decimalValue == 0 { return ("0x0", Data()) }

        // Build hex string from Decimal
        var bytes: [UInt8] = []
        while decimalValue > 0 {
            let (quotient, remainder) = divmod256(decimalValue)
            bytes.insert(UInt8(truncating: remainder as NSDecimalNumber), at: 0)
            decimalValue = quotient
        }

        hexResult = "0x" + bytes.map { String(format: "%02x", $0) }.joined()
        // Strip leading zero bytes for hex but keep at least one
        return (hexResult, Data(bytes))
    }

    /// Convert amount to smallest unit with specific decimal places (not always 18).
    private func amountToWeiWithDecimals(_ amount: Double, decimals: Int) -> (hex: String, bytes: Data) {
        // For 18 decimals, use the existing precise method
        if decimals == 18 { return amountToWei(amount) }

        // For other decimals, use Decimal for precision
        let dec = Decimal(amount) * Decimal(sign: .plus, exponent: decimals, significand: 1)
        var rounded = Decimal()
        var mutable = dec
        NSDecimalRound(&rounded, &mutable, 0, .down)

        // Convert to bytes
        var bytes: [UInt8] = []
        var remaining = rounded
        if remaining == 0 { return ("0x0", Data()) }

        while remaining > 0 {
            let (q, r) = divmod256(remaining)
            bytes.insert(UInt8(truncating: r as NSDecimalNumber), at: 0)
            remaining = q
        }

        let hex = "0x" + bytes.map { String(format: "%02x", $0) }.joined()
        return (hex, Data(bytes))
    }

    /// Divide a Decimal by 256, return (quotient, remainder)
    private func divmod256(_ value: Decimal) -> (Decimal, Decimal) {
        let divisor = Decimal(256)
        var quotient = value / divisor
        var rounded = Decimal()
        NSDecimalRound(&rounded, &quotient, 0, .down)
        let remainder = value - rounded * divisor
        return (rounded, remainder)
    }

    /// Build, sign and send a transaction to transfer native HYPE from HyperEVM to HyperCore.
    /// Sends HYPE as native value to the 0x2222... system address.
    func transferHYPEToCore(amountHYPE: Double, walletAddress: String, privateKey: Data) async throws -> String {
        let (valueHex, valueBytes) = amountToWei(amountHYPE)

        print("[EVM] Transferring \(amountHYPE) HYPE → Core, wei hex: \(valueHex)")

        // Estimate gas
        let txForEstimate: [String: Any] = [
            "from": walletAddress,
            "to": Self.coreTransferAddress,
            "value": valueHex
        ]
        let gasEstimate = (try? await estimateGas(tx: txForEstimate)) ?? 21000

        // Get nonce + dynamic gas
        let nonce = try await getTransactionCount(address: walletAddress)
        let baseFee = try await getBaseFee()
        let gasLimit: UInt64 = max(gasEstimate + 5000, 25000)
        let maxFeePerGas: UInt64 = baseFee * 3    // 3x baseFee for safety margin
        let maxPriorityFeePerGas: UInt64 = 0

        print("[EVM] baseFee=\(baseFee) (\(Double(baseFee)/1e9) gwei)")

        print("[EVM] nonce=\(nonce) gasLimit=\(gasLimit) maxFee=\(maxFeePerGas) value=\(valueHex) valueBytes=\(valueBytes.count)bytes")

        let toData = Data(hexString: Self.coreTransferAddress)!
        print("[EVM] to=\(toData.hexString) (\(toData.count) bytes)")

        let tx = EthereumTransaction(
            chainId: Self.chainId,
            nonce: nonce,
            maxPriorityFeePerGas: maxPriorityFeePerGas,
            maxFeePerGas: maxFeePerGas,
            gasLimit: gasLimit,
            to: toData,
            value: valueBytes,
            data: Data()
        )

        // Sign
        let hash = tx.signingHash()
        print("[EVM] signingHash=\(hash.hexString)")
        let sig = try TransactionSigner.ecdsaSignRecoverable(hash: hash, privateKey: privateKey)
        let r = Data(sig[0..<32])
        let s = Data(sig[32..<64])
        let v = sig[64]
        let yParity = v >= 27 ? v - 27 : v
        print("[EVM] v=\(v) yParity=\(yParity)")

        // Send
        let rawTx = tx.serialized(yParity: yParity, r: r, s: s)
        print("[EVM] rawTx=\(rawTx.count) bytes, hex prefix: \(rawTx.prefix(5).hexString)")

        let txHash = try await sendRawTransaction(rawTx)
        print("[EVM] TX sent: \(txHash)")
        return txHash
    }

    // MARK: - Transfer ERC20: EVM → Core

    /// Transfer an ERC20 token from HyperEVM to HyperCore by calling transfer(systemAddress, amount)
    /// on the token's EVM contract. Works for most tokens (PURR, JEFF, etc.) but NOT for USDC.
    func transferERC20ToCore(tokenContract: String, amount: Double, systemAddress: String,
                             walletAddress: String, privateKey: Data, decimals: Int = 18) async throws -> String {
        let (valueHex, _) = amountToWeiWithDecimals(amount, decimals: decimals)

        // Build ERC20 transfer calldata: transfer(address,uint256)
        // selector: 0xa9059cbb
        let paddedTo = "000000000000000000000000" + systemAddress.dropFirst(2)

        // Amount as 32-byte hex
        let cleanHex = valueHex.hasPrefix("0x") ? String(valueHex.dropFirst(2)) : valueHex
        let paddedAmount = String(repeating: "0", count: max(0, 64 - cleanHex.count)) + cleanHex

        let calldata = Data(hexString: "0xa9059cbb" + paddedTo + paddedAmount)!

        print("[EVM] ERC20 transfer: contract=\(tokenContract) to=\(systemAddress) amount=\(valueHex) decimals=\(decimals)")

        // Get nonce + dynamic gas
        let nonce = try await getTransactionCount(address: walletAddress)
        let baseFee = try await getBaseFee()
        let gasLimit: UInt64 = 100_000
        let maxFeePerGas: UInt64 = baseFee * 3
        let maxPriorityFeePerGas: UInt64 = 0

        print("[EVM] baseFee=\(baseFee) (\(Double(baseFee)/1e9) gwei)")

        let tx = EthereumTransaction(
            chainId: Self.chainId,
            nonce: nonce,
            maxPriorityFeePerGas: maxPriorityFeePerGas,
            maxFeePerGas: maxFeePerGas,
            gasLimit: gasLimit,
            to: Data(hexString: tokenContract)!,
            value: Data(),  // no native value for ERC20 transfer
            data: calldata
        )

        // Sign
        let hash = tx.signingHash()
        let sig = try TransactionSigner.ecdsaSignRecoverable(hash: hash, privateKey: privateKey)
        let r = Data(sig[0..<32])
        let s = Data(sig[32..<64])
        let yParity = sig[64] - 27

        // Send
        let rawTx = tx.serialized(yParity: yParity, r: r, s: s)
        let txHash = try await sendRawTransaction(rawTx)
        print("[EVM] ERC20 TX sent: \(txHash)")
        return txHash
    }

    // MARK: - Transfer USDC: EVM → Core (approve + deposit)

    /// USDC uses Circle's native ERC20 + CoreDepositWallet pattern:
    /// 1. approve(coreDepositWallet, amount) on Circle USDC
    /// 2. deposit(amount, destinationDex) on CoreDepositWallet
    /// destinationDex: 0xFFFFFFFF = spot, 0 = perps
    static let circleUSDC = "0xb88339cb7199b77e23db6e890353e22632ba630f"
    static let coreDepositWallet = "0x6b9e773128f453f5c2c60935ee2de2cbc5390a24"
    static let usdcDecimals = 6

    func transferUSDCToCore(amount: Double, walletAddress: String, privateKey: Data,
                            toSpot: Bool = true) async throws -> String {
        let (valueHex, _) = amountToWeiWithDecimals(amount, decimals: Self.usdcDecimals)
        let cleanHex = valueHex.hasPrefix("0x") ? String(valueHex.dropFirst(2)) : valueHex
        let paddedAmount = String(repeating: "0", count: max(0, 64 - cleanHex.count)) + cleanHex

        print("[EVM] USDC EVM→Core: amount=\(amount) valueHex=\(valueHex) toSpot=\(toSpot)")

        // ── Step 1: approve Circle USDC → CoreDepositWallet ──
        let paddedSpender = "000000000000000000000000" + Self.coreDepositWallet.dropFirst(2)
        let approveCalldata = Data(hexString: "0x095ea7b3" + paddedSpender + paddedAmount)!

        let baseFee = try await getBaseFee()
        let maxFeePerGas: UInt64 = baseFee * 3
        let nonce1 = try await getTransactionCount(address: walletAddress)

        print("[EVM] USDC approve: nonce=\(nonce1) baseFee=\(baseFee)")

        let approveTx = EthereumTransaction(
            chainId: Self.chainId,
            nonce: nonce1,
            maxPriorityFeePerGas: 0,
            maxFeePerGas: maxFeePerGas,
            gasLimit: 60_000,
            to: Data(hexString: Self.circleUSDC)!,
            value: Data(),
            data: approveCalldata
        )

        let approveHash = approveTx.signingHash()
        let approveSig = try TransactionSigner.ecdsaSignRecoverable(hash: approveHash, privateKey: privateKey)
        let approveYParity = approveSig[64] >= 27 ? approveSig[64] - 27 : approveSig[64]
        let approveRaw = approveTx.serialized(
            yParity: approveYParity,
            r: Data(approveSig[0..<32]),
            s: Data(approveSig[32..<64])
        )

        let approveTxHash = try await sendRawTransaction(approveRaw)
        print("[EVM] USDC approve TX: \(approveTxHash)")

        // Wait for approve to be mined (~2s on HyperEVM)
        try await waitForReceipt(txHash: approveTxHash, maxAttempts: 15)

        // ── Step 2: deposit(amount, destinationDex) on CoreDepositWallet ──
        // deposit(uint256 amount, uint32 destinationDex)
        // selector: 0x2b2dfd2c
        // destinationDex: 0xFFFFFFFF (uint32.max) = spot, 0 = perps
        // ABI encoding: uint32 is still left-padded to 32 bytes
        let destDex = toSpot ? "00000000000000000000000000000000000000000000000000000000ffffffff"
                             : "0000000000000000000000000000000000000000000000000000000000000000"
        let depositCalldata = Data(hexString: "0x2b2dfd2c" + paddedAmount + destDex)!

        let nonce2 = try await getTransactionCount(address: walletAddress)
        let baseFee2 = try await getBaseFee()
        let maxFeePerGas2: UInt64 = baseFee2 * 3

        print("[EVM] USDC deposit: nonce=\(nonce2) destDex=\(toSpot ? "spot" : "perps")")

        let depositTx = EthereumTransaction(
            chainId: Self.chainId,
            nonce: nonce2,
            maxPriorityFeePerGas: 0,
            maxFeePerGas: maxFeePerGas2,
            gasLimit: 200_000,
            to: Data(hexString: Self.coreDepositWallet)!,
            value: Data(),
            data: depositCalldata
        )

        let depositHash = depositTx.signingHash()
        let depositSig = try TransactionSigner.ecdsaSignRecoverable(hash: depositHash, privateKey: privateKey)
        let depositYParity = depositSig[64] >= 27 ? depositSig[64] - 27 : depositSig[64]
        let depositRaw = depositTx.serialized(
            yParity: depositYParity,
            r: Data(depositSig[0..<32]),
            s: Data(depositSig[32..<64])
        )

        let depositTxHash = try await sendRawTransaction(depositRaw)
        print("[EVM] USDC deposit TX: \(depositTxHash)")
        return depositTxHash
    }

    /// Wait for a transaction receipt (polling).
    private func waitForReceipt(txHash: String, maxAttempts: Int = 10) async throws {
        for i in 1...maxAttempts {
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            let result = try await call(method: "eth_getTransactionReceipt", params: [txHash])
            if let receipt = result as? [String: Any],
               let status = receipt["status"] as? String {
                if status == "0x1" {
                    print("[EVM] TX \(String(txHash.prefix(12)))... confirmed (attempt \(i))")
                    return
                } else {
                    throw RPCError.rpcError(code: -1, message: "Transaction reverted: \(txHash)")
                }
            }
            // receipt is null → not yet mined, retry
        }
        // If not confirmed after maxAttempts, proceed anyway (it may still go through)
        print("[EVM] TX \(String(txHash.prefix(12)))... not yet confirmed after \(maxAttempts)s, proceeding")
    }

    // MARK: - Helpers

    private func hexToUInt64(_ hex: String) -> UInt64 {
        let cleaned = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        return UInt64(cleaned, radix: 16) ?? 0
    }

    private func hexWeiToDouble(_ hex: String) -> Double {
        let cleaned = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        // Handle large numbers that don't fit in UInt64
        guard !cleaned.isEmpty else { return 0 }
        // Parse as hex, divide by 1e18
        if cleaned.count <= 16, let value = UInt64(cleaned, radix: 16) {
            return Double(value) / 1e18
        }
        // For very large balances, parse in chunks
        var result: Double = 0
        for char in cleaned {
            guard let digit = UInt8(String(char), radix: 16) else { return 0 }
            result = result * 16 + Double(digit)
        }
        return result / 1e18
    }
}
