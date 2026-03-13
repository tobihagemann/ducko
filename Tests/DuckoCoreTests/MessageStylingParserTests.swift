import Testing
@testable import DuckoCore

enum MessageStylingParserTests {
    // MARK: - Inline Styling

    struct InlineTests {
        @Test
        func `bold spans`() {
            let result = MessageStylingParser.parse("hello *world*")
            #expect(result == [.plain([.plain("hello "), .bold([.plain("world")])])])
        }

        @Test
        func `italic spans`() {
            let result = MessageStylingParser.parse("hello _world_")
            #expect(result == [.plain([.plain("hello "), .italic([.plain("world")])])])
        }

        @Test
        func `strikethrough spans`() {
            let result = MessageStylingParser.parse("hello ~world~")
            #expect(result == [.plain([.plain("hello "), .strikethrough([.plain("world")])])])
        }

        @Test
        func `code spans`() {
            let result = MessageStylingParser.parse("use `code` here")
            #expect(result == [.plain([.plain("use "), .code("code"), .plain(" here")])])
        }

        @Test
        func `plain text without markers`() {
            let result = MessageStylingParser.parse("just plain text")
            #expect(result == [.plain([.plain("just plain text")])])
        }

        @Test
        func `empty string`() {
            let result = MessageStylingParser.parse("")
            #expect(result == [.plain([.plain("")])])
        }

        @Test
        func `nested bold inside italic`() {
            let result = MessageStylingParser.parse("_hello *world*_")
            #expect(result == [.plain([.italic([.plain("hello "), .bold([.plain("world")])])])])
        }

        @Test
        func `code does not nest`() {
            let result = MessageStylingParser.parse("`*not bold*`")
            #expect(result == [.plain([.code("*not bold*")])])
        }
    }

    // MARK: - Boundary Rules

    struct BoundaryTests {
        @Test
        func `marker not at word boundary is plain`() {
            let result = MessageStylingParser.parse("foo*bar*baz")
            // *bar* fails boundary start because 'o' precedes '*'
            #expect(result == [.plain([.plain("foo*bar*baz")])])
        }

        @Test
        func `marker with inner whitespace at start fails`() {
            let result = MessageStylingParser.parse("* not bold*")
            #expect(result == [.plain([.plain("* not bold*")])])
        }

        @Test
        func `marker with inner whitespace at end fails`() {
            let result = MessageStylingParser.parse("*not bold *")
            #expect(result == [.plain([.plain("*not bold *")])])
        }
    }

    // MARK: - Block-Level

    struct BlockTests {
        @Test
        func `code block`() {
            let result = MessageStylingParser.parse("```\nhello world\n```")
            #expect(result == [.codeBlock("hello world")])
        }

        @Test
        func `multiline code block`() {
            let result = MessageStylingParser.parse("```\nline 1\nline 2\n```")
            #expect(result == [.codeBlock("line 1\nline 2")])
        }

        @Test
        func `code block suppresses inline parsing`() {
            let result = MessageStylingParser.parse("```\n*not bold*\n```")
            #expect(result == [.codeBlock("*not bold*")])
        }

        @Test
        func `unterminated code block treated as plain`() {
            let result = MessageStylingParser.parse("```\nhello")
            #expect(result == [.plain([.plain("```")]), .plain([.plain("hello")])])
        }

        @Test
        func `block quote`() {
            let result = MessageStylingParser.parse("> quoted text")
            #expect(result == [.blockQuote([.plain([.plain("quoted text")])])])
        }

        @Test
        func `multiline block quote`() {
            let result = MessageStylingParser.parse("> line 1\n> line 2")
            // Inner lines are joined into a single plain block
            #expect(result == [.blockQuote([.plain([.plain("line 1\nline 2")])])])
        }

        @Test
        func `block quote with styling`() {
            let result = MessageStylingParser.parse("> *bold* text")
            #expect(result == [.blockQuote([.plain([.bold([.plain("bold")]), .plain(" text")])])])
        }

        @Test
        func `mixed blocks`() {
            let result = MessageStylingParser.parse("hello\n> quote\nworld")
            #expect(result.count == 3)
            #expect(result[0] == .plain([.plain("hello")]))
            #expect(result[1] == .blockQuote([.plain([.plain("quote")])]))
            #expect(result[2] == .plain([.plain("world")]))
        }
    }
}
