import DuckoCore

/// Renders XEP-0393 styled blocks as ANSI terminal escape sequences.
enum MessageStylingANSIRenderer {
    static func render(_ blocks: [StyledBlock]) -> String {
        blocks.map { renderBlock($0) }.joined(separator: "\n")
    }

    private static func renderBlock(_ block: StyledBlock) -> String {
        switch block {
        case let .plain(spans):
            return spans.map { renderSpan($0) }.joined()
        case let .codeBlock(code):
            // Reverse video for code blocks
            return "\u{001B}[7m\(code)\u{001B}[27m"
        case let .blockQuote(inner):
            let content = inner.map { renderBlock($0) }.joined()
            return content.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "\u{001B}[2m|\u{001B}[22m \($0)" }
                .joined(separator: "\n")
        }
    }

    private static func renderSpan(_ span: StyledSpan) -> String {
        switch span {
        case let .plain(text):
            return text
        case let .bold(inner):
            return "\u{001B}[1m\(inner.map { renderSpan($0) }.joined())\u{001B}[22m"
        case let .italic(inner):
            return "\u{001B}[3m\(inner.map { renderSpan($0) }.joined())\u{001B}[23m"
        case let .strikethrough(inner):
            return "\u{001B}[9m\(inner.map { renderSpan($0) }.joined())\u{001B}[29m"
        case let .code(text):
            return "\u{001B}[7m\(text)\u{001B}[27m"
        }
    }
}
