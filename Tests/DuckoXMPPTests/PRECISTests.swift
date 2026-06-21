import Testing
@testable import DuckoXMPP

enum PRECISTests {
    struct UsernameCaseMapped {
        @Test(arguments: [
            ("user", "user"),
            ("User", "user"), // case mapping (lowercase)
            ("\u{FF21}", "a"), // fullwidth A → width-mapped to ASCII A → lowercased
            ("e\u{0301}", "é"), // NFC of decomposed e + combining acute
            ("\u{00DF}", "\u{00DF}") // ß stays ß (lowercase mapping, not case folding)
        ])
        func `Valid localparts normalize`(input: String, expected: String) {
            #expect(PRECIS.usernameCaseMapped(input) == expected)
        }

        @Test
        func `Sharp s is not folded to ss`() {
            let normalized = PRECIS.usernameCaseMapped("\u{00DF}")
            #expect(normalized == "\u{00DF}")
            #expect(normalized != "ss")
        }

        @Test(arguments: [
            "a b", // SPACE (U+0020) is DISALLOWED in IdentifierClass
            "a\u{0007}b", // control character
            "a\u{00D7}b" // MULTIPLICATION SIGN (Sm) is DISALLOWED in IdentifierClass
        ])
        func `Prohibited code points are rejected`(input: String) {
            #expect(PRECIS.usernameCaseMapped(input) == nil)
        }

        @Test
        func `Validate runs before case mapping`() {
            // U+2126 OHM SIGN is DISALLOWED (HasCompat), but lowercases to ω (PVALID). Validating
            // before case-mapping catches the original; lowercasing first would hide it.
            #expect(PRECIS.usernameCaseMapped("\u{2126}") == nil)
        }

        @Test
        func `RTL-then-LTR localpart fails the Bidi rule`() {
            // Hebrew aleph (R) followed by 'a' (L) violates RFC 5893 condition 2.
            #expect(PRECIS.usernameCaseMapped("\u{05D0}a") == nil)
        }

        @Test
        func `Middle dot is accepted only between ASCII l after case mapping`() {
            // Catalan ela geminada: contextual rule must run on the post-lowercase form (ŀl → l·l).
            #expect(PRECIS.usernameCaseMapped("L\u{00B7}L") == "l\u{00B7}l")
            #expect(PRECIS.usernameCaseMapped("a\u{00B7}b") == nil)
        }

        @Test
        func `Script-dependent contextual rules are conservatively rejected`() {
            // Greek keraia (U+0375) needs Script(After) — deferred, so rejected.
            #expect(PRECIS.usernameCaseMapped("a\u{0375}b") == nil)
        }

        @Test
        func `Over-length localpart is rejected`() {
            #expect(PRECIS.usernameCaseMapped(String(repeating: "a", count: 1024)) == nil)
        }
    }

    struct OpaqueString {
        @Test
        func `Case is preserved`() {
            #expect(PRECIS.opaqueString("MyResource") == "MyResource")
        }

        @Test
        func `Non-ASCII space maps to ASCII space`() {
            #expect(PRECIS.opaqueString("a\u{00A0}b") == "a b") // NO-BREAK SPACE → U+0020
        }

        @Test
        func `Empty and control inputs are rejected`() {
            #expect(PRECIS.opaqueString("") == nil)
            #expect(PRECIS.opaqueString("a\u{0007}b") == nil)
        }

        @Test
        func `Symbols and punctuation are allowed`() {
            #expect(PRECIS.opaqueString("res/with/slashes") == "res/with/slashes")
        }

        @Test
        func `Over-length resourcepart is rejected`() {
            #expect(PRECIS.opaqueString(String(repeating: "a", count: 1024)) == nil)
        }
    }

    struct Contextual {
        private static func scalars(_ string: String) -> [Unicode.Scalar] {
            Array(string.unicodeScalars)
        }

        @Test
        func `Middle dot only between ASCII l`() {
            #expect(ContextualRules.satisfied(Self.scalars("l\u{00B7}l"), at: 1))
            #expect(!ContextualRules.satisfied(Self.scalars("a\u{00B7}b"), at: 1))
        }

        @Test
        func `ZWJ and ZWNJ require a preceding Virama`() {
            // DEVANAGARI KA + VIRAMA (CCC 9) + ZWJ.
            #expect(ContextualRules.satisfied(Self.scalars("\u{0915}\u{094D}\u{200D}"), at: 2))
            #expect(!ContextualRules.satisfied(Self.scalars("a\u{200D}"), at: 1))
            #expect(!ContextualRules.satisfied(Self.scalars("a\u{200C}"), at: 1))
        }

        @Test
        func `Arabic-Indic and Extended Arabic-Indic digits cannot be mixed`() {
            #expect(ContextualRules.satisfied(Self.scalars("\u{0660}\u{0661}"), at: 0))
            #expect(!ContextualRules.satisfied(Self.scalars("\u{0660}\u{06F0}"), at: 0))
        }

        @Test
        func `Script-dependent rules are rejected`() {
            // Greek keraia (U+0375), Hebrew geresh (U+05F3), Katakana middle dot (U+30FB).
            #expect(!ContextualRules.satisfied(Self.scalars("a\u{0375}b"), at: 1))
            #expect(!ContextualRules.satisfied(Self.scalars("a\u{05F3}b"), at: 1))
            #expect(!ContextualRules.satisfied(Self.scalars("a\u{30FB}b"), at: 1))
        }
    }
}
