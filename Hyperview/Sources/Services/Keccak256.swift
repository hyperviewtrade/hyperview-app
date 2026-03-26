import Foundation

// MARK: - Keccak-256 (SHA-3 variant used by Ethereum)
// Pure Swift implementation — no external dependency needed.
// Used to derive Ethereum addresses from secp256k1 public keys.

struct Keccak256 {
    static func hash(data: Data) -> Data {
        var state = [UInt64](repeating: 0, count: 25)
        let rateBytes = 136  // (1600 - 512) / 8 for Keccak-256
        let outputBytes = 32

        // Pad the message (Keccak padding: append 0x01 ... 0x80)
        var message = [UInt8](data)
        let blockCount = (message.count + 1 + rateBytes - 1) / rateBytes
        let paddedLen = blockCount * rateBytes
        message.append(0x01)
        while message.count < paddedLen - 1 { message.append(0x00) }
        // XOR last byte with 0x80 (if paddedLen == message.count + 1, combine)
        if message.count == paddedLen {
            message[message.count - 1] |= 0x80
        } else {
            message.append(0x80)
        }

        // Absorb
        for blockStart in stride(from: 0, to: message.count, by: rateBytes) {
            let end = min(blockStart + rateBytes, message.count)
            for i in stride(from: blockStart, to: end - 7, by: 8) {
                let wordIdx = (i - blockStart) / 8
                let word = UInt64(message[i])
                    | (UInt64(message[i+1]) << 8)
                    | (UInt64(message[i+2]) << 16)
                    | (UInt64(message[i+3]) << 24)
                    | (UInt64(message[i+4]) << 32)
                    | (UInt64(message[i+5]) << 40)
                    | (UInt64(message[i+6]) << 48)
                    | (UInt64(message[i+7]) << 56)
                state[wordIdx] ^= word
            }
            keccakF1600(&state)
        }

        // Squeeze
        var output = Data(count: outputBytes)
        for i in 0..<(outputBytes / 8) {
            let word = state[i]
            for b in 0..<8 {
                if i * 8 + b < outputBytes {
                    output[i * 8 + b] = UInt8((word >> (b * 8)) & 0xFF)
                }
            }
        }
        return output
    }

    // MARK: - Keccak-f[1600] permutation

    private static let roundConstants: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
        0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]

    private static let rotationOffsets: [Int] = [
         0,  1, 62, 28, 27,
        36, 44,  6, 55, 20,
         3, 10, 43, 25, 39,
        41, 45, 15, 21,  8,
        18,  2, 61, 56, 14,
    ]

    private static let piIndices: [Int] = [
         0, 10, 20,  5, 15,
        16,  1, 11, 21,  6,
         7, 17,  2, 12, 22,
        23,  8, 18,  3, 13,
        14, 24,  9, 19,  4,
    ]

    private static func keccakF1600(_ state: inout [UInt64]) {
        for round in 0..<24 {
            // θ (theta)
            var c = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
            }
            var d = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                d[x] = c[(x + 4) % 5] ^ rotl64(c[(x + 1) % 5], 1)
            }
            for x in 0..<5 {
                for y in 0..<5 {
                    state[x + 5 * y] ^= d[x]
                }
            }

            // ρ (rho) and π (pi)
            var b = [UInt64](repeating: 0, count: 25)
            for i in 0..<25 {
                b[piIndices[i]] = rotl64(state[i], rotationOffsets[i])
            }

            // χ (chi)
            for y in 0..<5 {
                for x in 0..<5 {
                    state[x + 5 * y] = b[x + 5 * y] ^ (~b[(x + 1) % 5 + 5 * y] & b[(x + 2) % 5 + 5 * y])
                }
            }

            // ι (iota)
            state[0] ^= roundConstants[round]
        }
    }

    private static func rotl64(_ x: UInt64, _ n: Int) -> UInt64 {
        guard n > 0 else { return x }
        return (x << n) | (x >> (64 - n))
    }
}
