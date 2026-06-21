import Testing
@testable import DuckoXMPP

/// Guards against Unicode-version skew between the pinned generated tables and the OS-supplied
/// NFC/lowercase used at runtime. The pinned version is recorded in the generated file; the
/// stdlib sentinels confirm the host matches, and representative code points lock the derived
/// values the algorithms depend on.
enum UnicodeTableConformanceTests {
    struct Versioning {
        @Test
        func `Pinned Unicode version`() {
            #expect(UnicodeTables.unicodeVersion == "17.0.0")
        }

        @Test
        func `Host stdlib matches the pinned version`() throws {
            // U+088F and U+0C5C are assigned in Unicode 17.0 but not 16.0; if the host stdlib
            // sees them as unassigned, its NFC/lowercase predate the tables.
            #expect(try #require(Unicode.Scalar(0x088F)?.properties.generalCategory) != .unassigned)
            #expect(try #require(Unicode.Scalar(0x0C5C)?.properties.generalCategory) != .unassigned)
        }
    }

    struct DerivedProperties {
        @Test(arguments: [
            (UInt32(0x0061), DerivedProperty.pvalid), // 'a'
            (0x0020, .disallowed), // SPACE
            (0x00DF, .pvalid), // ß (exception)
            (0x2126, .disallowed), // OHM SIGN (HasCompat)
            (0x200C, .contextj), // ZERO WIDTH NON-JOINER
            (0x00B7, .contexto), // MIDDLE DOT
            (0x0378, .unassigned) // unassigned
        ])
        func `IdentifierClass values`(codePoint: UInt32, expected: DerivedProperty) throws {
            #expect(try UnicodeProperties.identifierClass(#require(Unicode.Scalar(codePoint))) == expected)
        }

        @Test(arguments: [
            (UInt32(0x0020), DerivedProperty.pvalid), // SPACE is PVALID in FreeformClass
            (0x2126, .pvalid), // HasCompat is PVALID in FreeformClass
            (0x0061, .pvalid)
        ])
        func `FreeformClass values`(codePoint: UInt32, expected: DerivedProperty) throws {
            #expect(try UnicodeProperties.freeformClass(#require(Unicode.Scalar(codePoint))) == expected)
        }

        @Test(arguments: [
            (UInt32(0x0061), DerivedProperty.pvalid), // 'a'
            (0x0041, .disallowed), // 'A' is Unstable in IDNA2008
            (0x002D, .pvalid), // '-'
            (0x00DF, .pvalid)
        ])
        func `IDNA values`(codePoint: UInt32, expected: DerivedProperty) throws {
            #expect(try UnicodeProperties.idna(#require(Unicode.Scalar(codePoint))) == expected)
        }
    }

    struct BidiAndWidth {
        @Test(arguments: [
            (UInt32(0x0061), BidiClass.l), // 'a'
            (0x05D0, .r), // Hebrew aleph
            (0x0627, .al), // Arabic alef
            (0x0660, .an), // Arabic-Indic digit zero
            (0x0030, .en) // '0'
        ])
        func `Bidi classes`(codePoint: UInt32, expected: BidiClass) throws {
            #expect(try UnicodeProperties.bidiClass(#require(Unicode.Scalar(codePoint))) == expected)
        }

        @Test
        func `Width mapping covers fullwidth and ideographic space`() throws {
            #expect(try UnicodeProperties.widthMapping(#require(Unicode.Scalar(0xFF21))) == [#require(Unicode.Scalar(0x41))])
            #expect(try UnicodeProperties.widthMapping(#require(Unicode.Scalar(0x3000))) == [#require(Unicode.Scalar(0x20))])
            #expect(try UnicodeProperties.widthMapping(#require(Unicode.Scalar(0x61))) == nil)
        }
    }

    struct PartitionBoundaries {
        /// The binary-search accessor must resolve the endpoints of the code-point space and the
        /// exact transition between the control run and the ASCII7 PVALID run (0x20 → 0x21).
        @Test
        func `Lookup resolves partition endpoints and transitions`() throws {
            #expect(try UnicodeProperties.identifierClass(#require(Unicode.Scalar(0x00))) == .disallowed)
            #expect(try UnicodeProperties.identifierClass(#require(Unicode.Scalar(0x20))) == .disallowed)
            #expect(try UnicodeProperties.identifierClass(#require(Unicode.Scalar(0x21))) == .pvalid)
            #expect(try UnicodeProperties.identifierClass(#require(Unicode.Scalar(0x7E))) == .pvalid)
            #expect(try UnicodeProperties.identifierClass(#require(Unicode.Scalar(0x7F))) == .disallowed)
            #expect(try UnicodeProperties.identifierClass(#require(Unicode.Scalar(0x10FFFF))) == .disallowed)
        }
    }
}
