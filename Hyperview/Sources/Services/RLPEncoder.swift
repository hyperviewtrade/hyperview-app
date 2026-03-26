import Foundation

// MARK: - RLP Encoder
// Recursive Length Prefix encoding per Ethereum Yellow Paper appendix B.

enum RLP {

    /// Encode a single data item.
    static func encode(_ data: Data) -> Data {
        // Safe access via .first to avoid potential subscript crash on bridged Data
        guard let first = data.first else { return Data([0x80]) }
        if data.count == 1 && first < 0x80 { return Data([first]) }
        return lengthPrefix(data, offset: 0x80)
    }

    /// Encode a list of already-RLP-encoded items.
    static func encodeList(_ items: [Data]) -> Data {
        let payload = items.reduce(Data()) { $0 + $1 }
        return lengthPrefix(payload, offset: 0xc0)
    }

    /// Encode a UInt64 as RLP (big-endian, no leading zeros, 0 → empty data).
    static func encode(_ value: UInt64) -> Data {
        encode(bigEndianNoLeadingZeros(value))
    }

    // MARK: - Internal

    private static func lengthPrefix(_ payload: Data, offset: UInt8) -> Data {
        if payload.count <= 55 {
            return Data([offset + UInt8(payload.count)]) + payload
        }
        let lenBytes = bigEndianNoLeadingZeros(UInt64(payload.count))
        return Data([offset + 55 + UInt8(lenBytes.count)]) + lenBytes + payload
    }

    /// Big-endian bytes with leading zeros stripped. Zero → empty Data.
    static func bigEndianNoLeadingZeros(_ value: UInt64) -> Data {
        guard value != 0 else { return Data() }
        var be = withUnsafeBytes(of: value.bigEndian) { Data($0) }
        while be.first == 0 { be.removeFirst() }
        return be
    }

    /// Strip leading zeros from arbitrary data (for r, s values).
    static func stripLeadingZeros(_ data: Data) -> Data {
        guard let first = data.firstIndex(where: { $0 != 0 }) else { return Data() }
        return Data(data[first...])
    }
}
