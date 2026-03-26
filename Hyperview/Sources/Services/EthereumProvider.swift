import Combine
import Foundation
import WebKit
import SwiftUI

// MARK: - EthereumProvider
// Central bridge between JS (window.ethereum) and Swift wallet.
// Routes JSON-RPC methods, manages approval flows, signs transactions.

final class EthereumProvider: ObservableObject {
    static let handlerName = "ethereum"

    weak var webView: WKWebView?

    // Approval state
    @Published var showTransactionApproval = false
    @Published var showSignApproval = false
    @Published var pendingTransaction: PendingTransaction?
    @Published var pendingSignMessage: PendingSign?
    @Published var isProcessing = false

    private var transactionContinuation: CheckedContinuation<Bool, Never>?
    private var signContinuation: CheckedContinuation<Bool, Never>?

    private let rpc = ArbitrumRPC.shared
    private let arbitrumChainId: UInt64 = 42161

    // MARK: - Approval actions (called from UI)

    func approveTransaction() {
        showTransactionApproval = false
        transactionContinuation?.resume(returning: true)
        transactionContinuation = nil
    }

    func rejectTransaction() {
        showTransactionApproval = false
        transactionContinuation?.resume(returning: false)
        transactionContinuation = nil
    }

    func approveSign() {
        showSignApproval = false
        signContinuation?.resume(returning: true)
        signContinuation = nil
    }

    func rejectSign() {
        showSignApproval = false
        signContinuation?.resume(returning: false)
        signContinuation = nil
    }

    func reload() {
        webView?.reload()
    }

    // MARK: - JS response

    /// Sanitize a JS request ID to prevent injection
    private func sanitizeJSId(_ raw: String) -> String {
        raw.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    private func respond(id: String, result: Any) {
        let safeId = sanitizeJSId(id)
        let jsonResult: String
        if let str = result as? String {
            jsonResult = "'\(str.replacingOccurrences(of: "'", with: "\\'"))'"
        } else if let arr = result as? [String] {
            let items = arr.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" }.joined(separator: ",")
            jsonResult = "[\(items)]"
        } else if let num = result as? Int {
            jsonResult = "\(num)"
        } else if let b = result as? Bool {
            jsonResult = b ? "true" : "false"
        } else if result is NSNull {
            jsonResult = "null"
        } else {
            if let data = try? JSONSerialization.data(withJSONObject: result),
               let str = String(data: data, encoding: .utf8) {
                jsonResult = str
            } else {
                jsonResult = "null"
            }
        }
        let js = "window._hyperviewResponse('\(safeId)', \(jsonResult), null)"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func respondError(id: String, code: Int, message: String) {
        let safeId = sanitizeJSId(id)
        let safeMsg = message.replacingOccurrences(of: "'", with: "\\'")
        let js = "window._hyperviewResponse('\(safeId)', null, {code:\(code),message:'\(safeMsg)'})"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - Cleanup — cancel pending continuations on deallocation

    deinit {
        transactionContinuation?.resume(returning: false)
        transactionContinuation = nil
        signContinuation?.resume(returning: false)
        signContinuation = nil
    }

    // MARK: - Method routing

    func handleRequest(id: String, method: String, params: [Any]) {
        #if DEBUG
        print("[EthProvider] \(method) id=\(id) params=\(params)")
        #endif
        Task {
            do {
                switch method {

                case "eth_requestAccounts", "eth_accounts":
                    guard let addr = WalletManager.shared.connectedWallet?.address else {
                        respondError(id: id, code: 4001, message: "No wallet connected")
                        return
                    }
                    respond(id: id, result: [addr])

                case "eth_chainId":
                    respond(id: id, result: "0xa4b1")

                case "net_version":
                    respond(id: id, result: "42161")

                case "wallet_switchEthereumChain":
                    if let chain = (params.first as? [String: Any])?["chainId"] as? String,
                       chain.lowercased() == "0xa4b1" {
                        respond(id: id, result: NSNull())
                    } else {
                        respondError(id: id, code: 4902, message: "Only Arbitrum (0xa4b1) is supported")
                    }

                case "wallet_addEthereumChain":
                    // Accept if it's Arbitrum, reject otherwise
                    if let chain = (params.first as? [String: Any])?["chainId"] as? String,
                       chain.lowercased() == "0xa4b1" {
                        respond(id: id, result: NSNull())
                    } else {
                        respondError(id: id, code: 4902, message: "Only Arbitrum is supported")
                    }

                case "personal_sign":
                    try await handlePersonalSign(id: id, params: params)

                case "eth_signTypedData_v4", "eth_signTypedData_v3", "eth_signTypedData":
                    try await handleSignTypedData(id: id, params: params)

                case "eth_sendTransaction":
                    try await handleSendTransaction(id: id, params: params)

                default:
                    // Proxy all other calls to Arbitrum RPC
                    let result = try await rpc.proxy(method: method, params: params)
                    respond(id: id, result: result)
                }
            } catch {
                respondError(id: id, code: -32000, message: error.localizedDescription)
            }
        }
    }

    // MARK: - personal_sign

    private func handlePersonalSign(id: String, params: [Any]) async throws {
        // params: [messageHex, address] or [address, messageHex]
        guard params.count >= 2 else {
            respondError(id: id, code: -32602, message: "Invalid params")
            return
        }

        let (msgHex, _) = extractMessageAndAddress(params)
        let msgBytes = Data(hexString: msgHex) ?? Data(msgHex.utf8)

        // Decode message for display
        let displayMessage = String(data: msgBytes, encoding: .utf8) ?? msgHex

        // Show approval
        pendingSignMessage = PendingSign(id: id, message: displayMessage, typedData: nil)
        showSignApproval = true
        let approved = await withCheckedContinuation { continuation in
            self.signContinuation = continuation
        }
        guard approved else {
            respondError(id: id, code: 4001, message: "User rejected the request")
            return
        }

        // Face ID + sign
        guard await WalletManager.shared.authenticateForTransaction(),
              let pk = WalletManager.shared.loadPrivateKey() else {
            respondError(id: id, code: 4001, message: "Authentication failed")
            return
        }

        // Ethereum signed message prefix
        let prefix = "\u{19}Ethereum Signed Message:\n\(msgBytes.count)"
        let prefixed = Data(prefix.utf8) + msgBytes
        let hash = Keccak256.hash(data: prefixed)
        let sig = try TransactionSigner.ecdsaSignRecoverable(hash: hash, privateKey: pk)
        respond(id: id, result: sig.hexString)
    }

    // MARK: - eth_signTypedData_v4

    private func handleSignTypedData(id: String, params: [Any]) async throws {
        guard params.count >= 2 else {
            respondError(id: id, code: -32602, message: "Invalid params")
            return
        }

        // params: [address, typedDataJSON]
        let jsonStr: String
        if let s = params[1] as? String {
            jsonStr = s
        } else if let data = try? JSONSerialization.data(withJSONObject: params[1]),
                  let s = String(data: data, encoding: .utf8) {
            jsonStr = s
        } else {
            respondError(id: id, code: -32602, message: "Invalid typed data")
            return
        }

        guard let jsonData = jsonStr.data(using: .utf8),
              let typedData = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            respondError(id: id, code: -32602, message: "Cannot parse typed data")
            return
        }

        // Show approval
        let domainName = (typedData["domain"] as? [String: Any])?["name"] as? String ?? "Unknown"
        pendingSignMessage = PendingSign(id: id, message: "Sign message from \(domainName)", typedData: typedData)
        showSignApproval = true
        let approved = await withCheckedContinuation { continuation in
            self.signContinuation = continuation
        }
        guard approved else {
            respondError(id: id, code: 4001, message: "User rejected the request")
            return
        }

        guard await WalletManager.shared.authenticateForTransaction(),
              let pk = WalletManager.shared.loadPrivateKey() else {
            respondError(id: id, code: 4001, message: "Authentication failed")
            return
        }

        // EIP-712 hash
        let hash = try hashTypedData(typedData)
        let sig = try TransactionSigner.ecdsaSignRecoverable(hash: hash, privateKey: pk)
        respond(id: id, result: sig.hexString)
    }

    // MARK: - eth_sendTransaction

    private func handleSendTransaction(id: String, params: [Any]) async throws {
        guard let txObj = params.first as? [String: Any] else {
            respondError(id: id, code: -32602, message: "Invalid params")
            return
        }

        let to = txObj["to"] as? String ?? ""
        let valueHex = txObj["value"] as? String ?? "0x0"
        let dataHex = txObj["data"] as? String ?? "0x"

        // Parse value for display
        let valueWei = UInt64(valueHex.hasPrefix("0x") ? String(valueHex.dropFirst(2)) : valueHex, radix: 16) ?? 0
        let valueEth = Double(valueWei) / 1e18

        // Estimate gas
        let gasEstimate = try? await rpc.estimateGas(tx: txObj)

        pendingTransaction = PendingTransaction(
            id: id, to: to, valueEth: valueEth, dataSize: (Data(hexString: dataHex) ?? Data()).count,
            estimatedGas: gasEstimate ?? 0
        )
        showTransactionApproval = true
        isProcessing = false

        let approved = await withCheckedContinuation { continuation in
            self.transactionContinuation = continuation
        }
        guard approved else {
            respondError(id: id, code: 4001, message: "User rejected the request")
            return
        }

        isProcessing = true

        guard await WalletManager.shared.authenticateForTransaction(),
              let pk = WalletManager.shared.loadPrivateKey() else {
            isProcessing = false
            respondError(id: id, code: 4001, message: "Authentication failed")
            return
        }

        guard let walletAddr = WalletManager.shared.connectedWallet?.address else {
            isProcessing = false
            respondError(id: id, code: -32000, message: "No wallet")
            return
        }

        // Build transaction
        let nonce = try await rpc.getTransactionCount(address: walletAddr)
        let gasLimit = gasEstimate.map { $0 + $0 / 5 } ?? 300_000  // +20% buffer
        let baseFee = try await rpc.getBaseFee()
        let priorityFee = try await rpc.getMaxPriorityFee()
        let maxFee = baseFee * 2 + priorityFee

        let tx = EthereumTransaction(
            chainId: arbitrumChainId,
            nonce: nonce,
            maxPriorityFeePerGas: priorityFee,
            maxFeePerGas: maxFee,
            gasLimit: gasLimit,
            to: Data(hexString: to) ?? Data(),
            value: Data(hexString: valueHex) ?? Data(),
            data: Data(hexString: dataHex) ?? Data()
        )

        let hash = tx.signingHash()
        let sig = try TransactionSigner.ecdsaSignRecoverable(hash: hash, privateKey: pk)

        let r = Data(sig[0..<32])
        let s = Data(sig[32..<64])
        let yParity = sig[64] - 27  // EIP-1559 uses 0/1, not 27/28

        let rawTx = tx.serialized(yParity: yParity, r: r, s: s)
        let txHash = try await rpc.sendRawTransaction(rawTx)

        isProcessing = false
        respond(id: id, result: txHash)
    }

    // MARK: - EIP-712 generic hasher

    private func hashTypedData(_ typedData: [String: Any]) throws -> Data {
        guard let types = typedData["types"] as? [String: Any],
              let domain = typedData["domain"] as? [String: Any],
              let primaryType = typedData["primaryType"] as? String,
              let message = typedData["message"] as? [String: Any] else {
            throw SignerError.signingFailed("Invalid EIP-712 structure")
        }

        let domainSeparator = hashStruct("EIP712Domain", data: domain, types: types)
        let messageHash = hashStruct(primaryType, data: message, types: types)

        var digest = Data([0x19, 0x01])
        digest.append(domainSeparator)
        digest.append(messageHash)
        return Keccak256.hash(data: digest)
    }

    private func hashStruct(_ typeName: String, data: [String: Any], types: [String: Any]) -> Data {
        let typeHash = Keccak256.hash(data: Data(encodeType(typeName, types: types).utf8))
        var encoded = typeHash
        guard let fields = types[typeName] as? [[String: String]] else { return Keccak256.hash(data: encoded) }

        for field in fields {
            guard let name = field["name"], let type = field["type"] else { continue }
            let value = data[name]
            encoded.append(encodeField(value: value, type: type, types: types))
        }
        return Keccak256.hash(data: encoded)
    }

    private func encodeType(_ typeName: String, types: [String: Any]) -> String {
        guard let fields = types[typeName] as? [[String: String]] else { return "" }

        // Collect referenced types (excluding base types)
        var refs = Set<String>()
        for field in fields {
            guard let type = field["type"] else { continue }
            let baseType = type.replacingOccurrences(of: "[]", with: "")
            if types[baseType] != nil && baseType != typeName { refs.insert(baseType) }
        }

        let primary = "\(typeName)(" + fields.map { "\($0["type"] ?? "") \($0["name"] ?? "")" }.joined(separator: ",") + ")"
        let sorted = refs.sorted().map { encodeType($0, types: types) }.joined()
        return primary + sorted
    }

    private func encodeField(value: Any?, type: String, types: [String: Any]) -> Data {
        // Array type
        if type.hasSuffix("[]") {
            let baseType = String(type.dropLast(2))
            guard let arr = value as? [Any] else { return Data(repeating: 0, count: 32) }
            var encoded = Data()
            for item in arr {
                encoded.append(encodeField(value: item, type: baseType, types: types))
            }
            return Keccak256.hash(data: encoded)
        }

        // Struct type
        if types[type] != nil {
            guard let dict = value as? [String: Any] else { return Data(repeating: 0, count: 32) }
            return hashStruct(type, data: dict, types: types)
        }

        // Atomic types
        switch type {
        case "string":
            let str = value as? String ?? ""
            return Keccak256.hash(data: Data(str.utf8))
        case "bytes":
            let hex = value as? String ?? "0x"
            return Keccak256.hash(data: Data(hexString: hex) ?? Data())
        case "address":
            let addr = value as? String ?? ""
            let addrData = Data(hexString: addr) ?? Data(repeating: 0, count: 20)
            return TransactionSigner.padLeft(addrData, to: 32)
        case "bool":
            let b: Bool
            if let boolVal = value as? Bool { b = boolVal }
            else if let intVal = value as? Int { b = intVal != 0 }
            else { b = false }
            return TransactionSigner.padLeft(Data([b ? 1 : 0]), to: 32)
        default:
            // uint256, int256, bytes32, etc.
            if type.hasPrefix("uint") || type.hasPrefix("int") {
                if let str = value as? String, str.hasPrefix("0x") {
                    return TransactionSigner.padLeft(Data(hexString: str) ?? Data(), to: 32)
                }
                if let str = value as? String, let n = UInt64(str) {
                    return TransactionSigner.padLeft(RLP.bigEndianNoLeadingZeros(n), to: 32)
                }
                if let n = value as? Int {
                    return TransactionSigner.padLeft(RLP.bigEndianNoLeadingZeros(UInt64(n)), to: 32)
                }
                if let n = value as? Double {
                    return TransactionSigner.padLeft(RLP.bigEndianNoLeadingZeros(UInt64(n)), to: 32)
                }
                return Data(repeating: 0, count: 32)
            }
            if type.hasPrefix("bytes") {
                let hex = value as? String ?? "0x"
                let bytes = Data(hexString: hex) ?? Data()
                var padded = bytes
                if padded.count < 32 { padded.append(Data(repeating: 0, count: 32 - padded.count)) }
                return Data(padded.prefix(32))
            }
            return Data(repeating: 0, count: 32)
        }
    }

    // MARK: - Helpers

    private func extractMessageAndAddress(_ params: [Any]) -> (message: String, address: String) {
        let p0 = params[0] as? String ?? ""
        let p1 = params[1] as? String ?? ""
        // personal_sign: [data, address] — but some dapps send [address, data]
        if p0.hasPrefix("0x") && p0.count > 42 {
            return (p0, p1)
        }
        if p1.hasPrefix("0x") && p1.count > 42 {
            return (p1, p0)
        }
        // Default: first is message
        return (p0, p1)
    }
}

// MARK: - Weak proxy to avoid WKUserContentController retain cycle

final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var provider: EthereumProvider?

    init(delegate: EthereumProvider) {
        self.provider = delegate
    }

    func userContentController(_ uc: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let id     = body["id"]     as? String,
              let method = body["method"] as? String else { return }
        let params = body["params"] as? [Any] ?? []

        Task { @MainActor [weak provider] in
            provider?.handleRequest(id: id, method: method, params: params)
        }
    }
}

// MARK: - Models

struct PendingTransaction {
    let id: String
    let to: String
    let valueEth: Double
    let dataSize: Int
    let estimatedGas: UInt64
}

struct PendingSign {
    let id: String
    let message: String
    let typedData: [String: Any]?
}
