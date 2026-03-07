import Testing
@testable import DuckoUI

enum HTMLRenderingTests {
    struct BasicParsing {
        @Test
        func `Bold tags produce correct plain text`() throws {
            let attributed = try #require(HTMLAttributedStringParser.parse("<b>hello</b> world"))
            let plainText = String(attributed.characters)
            #expect(plainText == "hello world")
        }

        @Test
        func `Mixed inline tags produce correct plain text`() throws {
            let attributed = try #require(HTMLAttributedStringParser.parse("<b>bold</b> and <i>italic</i>"))
            let plainText = String(attributed.characters)
            #expect(plainText == "bold and italic")
        }

        @Test
        func `Invalid HTML still parses`() throws {
            let attributed = try #require(HTMLAttributedStringParser.parse("<b>unclosed bold"))
            let plainText = String(attributed.characters)
            #expect(plainText == "unclosed bold")
        }

        @Test
        func `Plain text without HTML passes through`() throws {
            let attributed = try #require(HTMLAttributedStringParser.parse("just plain text"))
            let plainText = String(attributed.characters)
            #expect(plainText == "just plain text")
        }

        @Test
        func `Parsed result strips font and foreground color`() throws {
            let attributed = try #require(HTMLAttributedStringParser.parse("<b>styled</b>"))
            #expect(attributed.runs.first?.font == nil)
            #expect(attributed.runs.first?.foregroundColor == nil)
        }
    }
}
