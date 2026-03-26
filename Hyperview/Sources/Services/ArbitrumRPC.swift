import Foundation

// MARK: - ArbitrumRPC
// JSON-RPC client for Arbitrum One. Used by the dapp browser to proxy
// read calls and broadcast signed transactions.

final class ArbitrumRPC: Sendable {
    static let shared = ArbitrumRPC()

    private let rpcURL = URL(string: "https://arb1.arbitrum.io/rpc")!
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

    // MARK: - Typed helpers

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
        guard let hex = result as? String else { throw RPCError.invalidResponse }
        return hexToUInt64(hex)
    }

    func sendRawTransaction(_ signedTx: Data) async throws -> String {
        let hex = "0x" + signedTx.map { String(format: "%02x", $0) }.joined()
        let result = try await call(method: "eth_sendRawTransaction", params: [hex])
        guard let txHash = result as? String else { throw RPCError.invalidResponse }
        return txHash
    }

    /// Pass-through: forward any JSON-RPC method to Arbitrum and return the raw result.
    func proxy(method: String, params: [Any]) async throws -> Any {
        try await call(method: method, params: params)
    }

    // MARK: - Hex parsing

    private func hexToUInt64(_ hex: String) -> UInt64 {
        let cleaned = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        return UInt64(cleaned, radix: 16) ?? 0
    }
}

// MARK: - RPCError

enum RPCError: LocalizedError {
    case rpcError(code: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .rpcError(_, let msg): return msg
        case .invalidResponse:      return "Invalid RPC response"
        }
    }
}
