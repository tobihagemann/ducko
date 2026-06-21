import Testing
@testable import DuckoXMPP

enum IDNATests {
    struct ULabelCanonicalForm {
        @Test(arguments: [
            ("xn--bcher-kva", "bücher"),
            ("xn--bcher-kva.example", "bücher.example"),
            ("bücher", "bücher"),
            ("Bücher.Example", "bücher.example") // case-folded, A-label decoded to U-label
        ])
        func `toUnicode produces U-labels`(input: String, expected: String) {
            #expect(IDNA.toUnicode(input) == expected)
        }

        @Test(arguments: [
            ("bücher", "xn--bcher-kva"),
            ("bücher.example", "xn--bcher-kva.example"),
            ("example.com", "example.com") // plain LDH unchanged
        ])
        func `toASCII produces A-labels`(input: String, expected: String) {
            #expect(IDNA.toASCII(input) == expected)
        }

        @Test
        func `ASCII LDH domains are byte-identical under toUnicode`() {
            #expect(IDNA.toUnicode("User.Example.COM") == "user.example.com")
            #expect(IDNA.toUnicode("a-b.c-d.example") == "a-b.c-d.example")
        }

        @Test
        func `Fullwidth Latin labels are width-mapped (RFC 7622 §3.2.2)`() {
            // FULLWIDTH LATIN CAPITAL LETTER A (U+FF21) folds to "a" rather than being rejected.
            #expect(IDNA.toUnicode("\u{FF21}.example") == "a.example")
            #expect(IDNA.toASCII("\u{FF21}.example") == "a.example")
        }
    }

    struct Names {
        @Test
        func `names splits an IDN domain into U-label stream and A-label lookup`() throws {
            let names = try #require(IDNA.names(for: "Bücher.Example"))
            #expect(names.stream == "bücher.example")
            #expect(names.lookup == "xn--bcher-kva.example")
        }

        @Test
        func `names returns ASCII domains unchanged in both forms`() throws {
            let names = try #require(IDNA.names(for: "example.com"))
            #expect(names.stream == "example.com")
            #expect(names.lookup == "example.com")
        }

        @Test
        func `names returns nil for a domain with no A-label`() {
            #expect(IDNA.names(for: "bad domain.example") == nil)
        }
    }

    struct Idempotence {
        @Test(arguments: ["Bücher.Example", "example.com", "xn--bcher-kva.example"])
        func `toUnicode is idempotent`(input: String) throws {
            let once = try #require(IDNA.toUnicode(input))
            #expect(IDNA.toUnicode(once) == once)
        }

        @Test(arguments: ["bücher.example", "example.com", "xn--bcher-kva.example"])
        func `toASCII is idempotent`(input: String) throws {
            let once = try #require(IDNA.toASCII(input))
            #expect(IDNA.toASCII(once) == once)
        }
    }

    struct Rejection {
        @Test(arguments: [
            "-foo.example", // leading hyphen
            "foo-.example", // trailing hyphen
            "ab--cd.example", // reserved positions 3–4 without a real xn-- prefix
            "foo..example", // empty label
            ".example", // leading empty label
            "foo bar.example", // space is not LDH
            "exa_mple.com" // underscore is not LDH
        ])
        func `Invalid domains return nil`(input: String) {
            #expect(IDNA.toUnicode(input) == nil)
        }

        @Test
        func `Over-long label is rejected`() {
            let label = String(repeating: "a", count: 64)
            #expect(IDNA.toUnicode("\(label).example") == nil)
            #expect(IDNA.toUnicode("\(String(repeating: "a", count: 63)).example") != nil)
        }
    }

    struct ALabelRejection {
        @Test(arguments: [
            "xn--trusted-.example", // decodes to pure ASCII "trusted" — spoofing vector
            "xn--.example", // empty Punycode suffix
            "xn--!!.example" // invalid Punycode digits
        ])
        func `Malformed or fake xn-- labels are rejected`(input: String) {
            #expect(IDNA.toUnicode(input) == nil)
        }

        @Test(arguments: [
            "ü-.example", // non-ASCII label with a trailing hyphen
            "\u{0301}a.example" // label beginning with a combining mark (U+0301)
        ])
        func `Non-ASCII labels obey RFC 5891 structural rules`(input: String) {
            #expect(IDNA.toUnicode(input) == nil)
        }

        @Test
        func `Domain exceeding 253 octets is rejected`() {
            let label = String(repeating: "a", count: 63)
            let oversized = Array(repeating: label, count: 5).joined(separator: ".") // 319 octets
            #expect(IDNA.toUnicode(oversized) == nil)
        }

        @Test
        func `A non-ASCII label that case-maps to ASCII becomes an LDH label`() {
            // KELVIN SIGN (U+212A) lowercases to "k"; it must emit the LDH label, not a fake A-label.
            #expect(IDNA.toUnicode("\u{212A}.example") == "k.example")
            #expect(IDNA.toASCII("\u{212A}.example") == "k.example")
        }

        @Test
        func `A-label decoding to a non-NFC sequence is rejected`() throws {
            // Encode the decomposed "e + combining acute"; its A-label decodes to a non-NFC form.
            let acute = try #require(Unicode.Scalar(0x0301))
            let suffix = try #require(Punycode.encode([Unicode.Scalar("e"), acute]))
            #expect(IDNA.toUnicode("xn--\(suffix).example") == nil)
        }
    }

    struct BidiDomainContext {
        @Test
        func `RTL label followed by digit-leading ASCII is rejected`() {
            // The Arabic first label makes the whole domain a Bidi name, so the rule applies to
            // every label; "1abc" starts with European Number → fails condition 1.
            #expect(IDNA.toUnicode("\u{0627}\u{0628}.1abc") == nil)
        }

        @Test
        func `RTL label followed by letter-leading ASCII is accepted`() {
            #expect(IDNA.toUnicode("\u{0627}\u{0628}.example") == "\u{0627}\u{0628}.example")
        }

        @Test
        func `RTL label mixing European and Arabic numbers is rejected`() {
            // "ا0٠": AL + EN (U+0030) + AN (U+0660) violates RFC 5893 condition 4.
            #expect(IDNA.toUnicode("\u{0627}0\u{0660}.example") == nil)
        }

        @Test
        func `Pure-LTR multi-label domain is accepted`() {
            #expect(IDNA.toUnicode("foo.bar123.example") == "foo.bar123.example")
        }
    }

    struct IPLiterals {
        @Test(arguments: [
            "192.168.1.1",
            "192.168.1.1.", // trailing root dot stripped
            "[2001:db8::1]",
            "[2001:DB8::1]" // hex digits lowercased
        ])
        func `IP literals are accepted`(input: String) {
            #expect(IDNA.toUnicode(input) != nil)
        }

        @Test
        func `IPv6 hex is lowercased and root dot stripped`() {
            #expect(IDNA.toUnicode("[2001:DB8::1].") == "[2001:db8::1]")
        }

        @Test
        func `IPv6 zone-id is preserved verbatim`() {
            #expect(IDNA.toUnicode("[fe80::1%25en0]") == "[fe80::1%25en0]")
        }

        @Test
        func `Malformed bracketed literal is rejected`() {
            #expect(IDNA.toUnicode("[not-an-address]") == nil)
        }
    }
}
