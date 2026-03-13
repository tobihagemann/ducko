import DuckoCore
import Testing
@testable import DuckoCLI

struct MessageStylingANSIRendererTests {
    @Test
    func `bold uses ANSI bold codes`() {
        let blocks: [StyledBlock] = [.plain([.bold([.plain("hello")])])]
        let output = MessageStylingANSIRenderer.render(blocks)
        #expect(output.contains("\u{001B}[1m"))
        #expect(output.contains("\u{001B}[22m"))
        #expect(output.contains("hello"))
    }

    @Test
    func `italic uses ANSI italic codes`() {
        let blocks: [StyledBlock] = [.plain([.italic([.plain("hello")])])]
        let output = MessageStylingANSIRenderer.render(blocks)
        #expect(output.contains("\u{001B}[3m"))
        #expect(output.contains("\u{001B}[23m"))
    }

    @Test
    func `strikethrough uses ANSI strikethrough codes`() {
        let blocks: [StyledBlock] = [.plain([.strikethrough([.plain("hello")])])]
        let output = MessageStylingANSIRenderer.render(blocks)
        #expect(output.contains("\u{001B}[9m"))
        #expect(output.contains("\u{001B}[29m"))
    }

    @Test
    func `code uses reverse video`() {
        let blocks: [StyledBlock] = [.plain([.code("hello")])]
        let output = MessageStylingANSIRenderer.render(blocks)
        #expect(output.contains("\u{001B}[7m"))
        #expect(output.contains("\u{001B}[27m"))
    }

    @Test
    func `code block uses reverse video`() {
        let blocks: [StyledBlock] = [.codeBlock("hello")]
        let output = MessageStylingANSIRenderer.render(blocks)
        #expect(output.contains("\u{001B}[7m"))
        #expect(output.contains("\u{001B}[27m"))
    }

    @Test
    func `block quote uses dim pipe prefix`() {
        let blocks: [StyledBlock] = [.blockQuote([.plain([.plain("hello")])])]
        let output = MessageStylingANSIRenderer.render(blocks)
        #expect(output.contains("\u{001B}[2m|\u{001B}[22m"))
        #expect(output.contains("hello"))
    }

    @Test
    func `plain text passes through unchanged`() {
        let blocks: [StyledBlock] = [.plain([.plain("hello world")])]
        let output = MessageStylingANSIRenderer.render(blocks)
        #expect(output == "hello world")
    }

    @Test
    func `multiple blocks separated by newlines`() {
        let blocks: [StyledBlock] = [
            .plain([.plain("hello")]),
            .plain([.plain("world")])
        ]
        let output = MessageStylingANSIRenderer.render(blocks)
        #expect(output == "hello\nworld")
    }
}
