import Foundation

// MARK: - EIP-1559 Transaction Builder
// Builds, hashes, and serializes type-2 (EIP-1559) Ethereum transactions.

struct EthereumTransaction {
    let chainId: UInt64              // 42161 for Arbitrum
    let nonce: UInt64
    let maxPriorityFeePerGas: UInt64
    let maxFeePerGas: UInt64
    let gasLimit: UInt64
    let to: Data                     // 20 bytes
    let value: Data                  // big-endian uint256, no leading zeros
    let data: Data                   // calldata
    // accessList always empty for our use case

    /// Keccak-256 hash of the unsigned EIP-1559 envelope.
    /// = keccak256(0x02 || rlp([chainId, nonce, maxPriorityFeePerGas,
    ///   maxFeePerGas, gasLimit, to, value, data, accessList]))
    func signingHash() -> Data {
        let items: [Data] = [
            RLP.encode(chainId),
            RLP.encode(nonce),
            RLP.encode(maxPriorityFeePerGas),
            RLP.encode(maxFeePerGas),
            RLP.encode(gasLimit),
            RLP.encode(to),
            RLP.encode(value.isEmpty ? Data() : RLP.stripLeadingZeros(value)),
            RLP.encode(data),
            RLP.encodeList([]),  // empty access list
        ]
        let payload = Data([0x02]) + RLP.encodeList(items)
        return Keccak256.hash(data: payload)
    }

    /// Serialize the signed transaction for broadcast.
    /// = 0x02 || rlp([chainId, nonce, ..., accessList, yParity, r, s])
    func serialized(yParity: UInt8, r: Data, s: Data) -> Data {
        let items: [Data] = [
            RLP.encode(chainId),
            RLP.encode(nonce),
            RLP.encode(maxPriorityFeePerGas),
            RLP.encode(maxFeePerGas),
            RLP.encode(gasLimit),
            RLP.encode(to),
            RLP.encode(value.isEmpty ? Data() : RLP.stripLeadingZeros(value)),
            RLP.encode(data),
            RLP.encodeList([]),  // empty access list
            RLP.encode(yParity == 0 ? Data() : Data([yParity])),
            RLP.encode(RLP.stripLeadingZeros(r)),
            RLP.encode(RLP.stripLeadingZeros(s)),
        ]
        return Data([0x02]) + RLP.encodeList(items)
    }
}

// MARK: - Hex Utilities

extension Data {
    /// Init from a hex string (with or without "0x" prefix).
    init?(hexString: String) {
        let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    /// Hex string with 0x prefix.
    var hexString: String {
        "0x" + map { String(format: "%02x", $0) }.joined()
    }
}
