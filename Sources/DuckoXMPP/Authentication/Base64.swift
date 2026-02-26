/// Standalone base64 encode/decode using only the Swift stdlib (no Foundation).
enum Base64 {
    private static let encodeTable: [UInt8] = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8
    )

    /// Decoding lookup: ASCII value → 6-bit value, or 0xFF for invalid.
    private static let decodeTable: [UInt8] = {
        var table = [UInt8](repeating: 0xFF, count: 256)
        for (i, byte) in encodeTable.enumerated() {
            table[Int(byte)] = UInt8(i)
        }
        return table
    }()

    // MARK: - Encode

    static func encode(_ bytes: [UInt8]) -> String {
        var result: [UInt8] = []
        result.reserveCapacity((bytes.count + 2) / 3 * 4)

        var i = 0
        while i + 2 < bytes.count {
            let b0 = bytes[i], b1 = bytes[i + 1], b2 = bytes[i + 2]
            result.append(encodeTable[Int(b0 >> 2)])
            result.append(encodeTable[Int((b0 & 0x03) << 4 | b1 >> 4)])
            result.append(encodeTable[Int((b1 & 0x0F) << 2 | b2 >> 6)])
            result.append(encodeTable[Int(b2 & 0x3F)])
            i += 3
        }

        let remaining = bytes.count - i
        if remaining == 1 {
            let b0 = bytes[i]
            result.append(encodeTable[Int(b0 >> 2)])
            result.append(encodeTable[Int((b0 & 0x03) << 4)])
            result.append(UInt8(ascii: "="))
            result.append(UInt8(ascii: "="))
        } else if remaining == 2 {
            let b0 = bytes[i], b1 = bytes[i + 1]
            result.append(encodeTable[Int(b0 >> 2)])
            result.append(encodeTable[Int((b0 & 0x03) << 4 | b1 >> 4)])
            result.append(encodeTable[Int((b1 & 0x0F) << 2)])
            result.append(UInt8(ascii: "="))
        }

        return String(decoding: result, as: UTF8.self)
    }

    static func encode(_ string: String) -> String {
        encode(Array(string.utf8))
    }

    // MARK: - Decode

    // swiftlint:disable:next cyclomatic_complexity
    static func decode(_ string: String) -> [UInt8]? {
        var input: [UInt8] = []
        input.reserveCapacity(string.utf8.count)
        for byte in string.utf8 {
            // Skip whitespace (CR, LF, space, tab)
            if byte == 0x0D || byte == 0x0A || byte == 0x20 || byte == 0x09 { continue }
            input.append(byte)
        }

        guard input.count % 4 == 0 else { return nil }
        if input.isEmpty { return [] }

        // Count padding and validate it only appears at the end
        let eq = UInt8(ascii: "=")
        var paddingCount = 0
        if input[input.count - 1] == eq { paddingCount += 1 }
        if input.count >= 2, input[input.count - 2] == eq { paddingCount += 1 }

        // Padding of 3rd char requires 4th char to also be padding
        if paddingCount == 1, input[input.count - 2] == eq { return nil }

        var result: [UInt8] = []
        result.reserveCapacity(input.count / 4 * 3 - paddingCount)

        let lastQuartetStart = input.count - 4
        var i = 0
        while i < input.count {
            let isLastQuartet = i == lastQuartetStart
            let char2 = input[i + 2]
            let char3 = input[i + 3]

            // Padding is only valid in the final quartet
            if !isLastQuartet && (char2 == eq || char3 == eq) { return nil }

            // If 3rd char is padding, 4th must also be padding
            if char2 == eq && char3 != eq { return nil }

            let c0 = decodeTable[Int(input[i])]
            let c1 = decodeTable[Int(input[i + 1])]
            let c2 = char2 == eq ? UInt8(0) : decodeTable[Int(char2)]
            let c3 = char3 == eq ? UInt8(0) : decodeTable[Int(char3)]

            if c0 == 0xFF || c1 == 0xFF { return nil }
            if char2 != eq, c2 == 0xFF { return nil }
            if char3 != eq, c3 == 0xFF { return nil }

            result.append(c0 << 2 | c1 >> 4)
            if char2 != eq {
                result.append((c1 & 0x0F) << 4 | c2 >> 2)
            }
            if char3 != eq {
                result.append((c2 & 0x03) << 6 | c3)
            }

            i += 4
        }

        return result
    }

    /// Decodes a base64 string to a UTF-8 string, or `nil` if invalid.
    static func decodeString(_ string: String) -> String? {
        guard let bytes = decode(string) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
