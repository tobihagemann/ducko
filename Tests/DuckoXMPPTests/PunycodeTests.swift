import Testing
@testable import DuckoXMPP

enum PunycodeTests {
    private static func scalars(_ values: [UInt32]) -> [Unicode.Scalar] {
        values.map { Unicode.Scalar($0)! }
    }

    struct RFC3492Vectors {
        /// RFC 3492 §7.1 sample strings (ACE prefix omitted).
        @Test(arguments: [
            ([0x644, 0x64A, 0x647, 0x645, 0x627, 0x628, 0x62A, 0x643, 0x644, 0x645, 0x648,
              0x634, 0x639, 0x631, 0x628, 0x64A, 0x61F], "egbpdaj6bu4bxfgehfvwxn"), // Arabic
            ([0x4ED6, 0x4EEC, 0x4E3A, 0x4EC0, 0x4E48, 0x4E0D, 0x8BF4, 0x4E2D, 0x6587],
             "ihqwcrb4cv8a8dqg056pqjye"), // Chinese (simplified)
            ([0x0050, 0x0072, 0x006F, 0x010D, 0x0070, 0x0072, 0x006F, 0x0073, 0x0074, 0x011B,
              0x006E, 0x0065, 0x006D, 0x006C, 0x0075, 0x0076, 0x00ED, 0x010D, 0x0065, 0x0073,
              0x006B, 0x0079], "Proprostnemluvesky-uyb24dma41a"), // Czech
            ([0x306A, 0x305C, 0x307F, 0x3093, 0x306A, 0x65E5, 0x672C, 0x8A9E, 0x3092, 0x8A71,
              0x3057, 0x3066, 0x304F, 0x308C, 0x306A, 0x3044, 0x306E, 0x304B],
             "n8jok5ay5dzabd5bym9f0cm5685rrjetr6pdxa") // Japanese
        ])
        func `Encode matches RFC vector`(codePoints: [UInt32], expected: String) {
            #expect(Punycode.encode(scalars(codePoints)) == expected)
        }

        @Test(arguments: [
            ("egbpdaj6bu4bxfgehfvwxn", [0x644, 0x64A, 0x647, 0x645, 0x627, 0x628, 0x62A, 0x643,
                                        0x644, 0x645, 0x648, 0x634, 0x639, 0x631, 0x628, 0x64A, 0x61F]),
            ("ihqwcrb4cv8a8dqg056pqjye", [0x4ED6, 0x4EEC, 0x4E3A, 0x4EC0, 0x4E48, 0x4E0D, 0x8BF4,
                                          0x4E2D, 0x6587]),
            ("Proprostnemluvesky-uyb24dma41a", [0x0050, 0x0072, 0x006F, 0x010D, 0x0070, 0x0072,
                                                0x006F, 0x0073, 0x0074, 0x011B, 0x006E, 0x0065,
                                                0x006D, 0x006C, 0x0075, 0x0076, 0x00ED, 0x010D,
                                                0x0065, 0x0073, 0x006B, 0x0079])
        ])
        func `Decode matches RFC vector`(encoded: String, codePoints: [UInt32]) throws {
            let decoded = try #require(Punycode.decode(Substring(encoded)))
            #expect(decoded == scalars(codePoints))
        }

        @Test(arguments: ["bcher-kva", "egbpdaj6bu4bxfgehfvwxn", "n8jok5ay5dzabd5bym9f0cm5685rrjetr6pdxa"])
        func `Encode-decode round-trips`(encoded: String) throws {
            let decoded = try #require(Punycode.decode(Substring(encoded)))
            #expect(Punycode.encode(decoded) == encoded)
        }
    }

    struct MalformedInput {
        /// Fail-closed (RFC 3492 §6.2): malformed/overflowing input returns nil, never traps.
        @Test(arguments: [
            "foo bar", // space is not a Punycode digit
            "abc!def", // punctuation is not a digit
            "99999999999999999999999999", // forces variable-length-integer overflow
            "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" // forces overflow on accumulated delta
        ])
        func `Malformed input returns nil`(input: String) {
            #expect(Punycode.decode(Substring(input)) == nil)
        }
    }
}
