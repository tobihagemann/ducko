/// Replaces common text emoticons with emoji in outgoing messages.
struct EmojiFilter: MessageFilter {
    let priority = 100

    private static let replacements: [(pattern: String, emoji: String)] = [
        (":)", "\u{1F60A}"),
        (":(", "\u{1F61E}"),
        (":D", "\u{1F604}"),
        (";)", "\u{1F609}"),
        (":P", "\u{1F61B}"),
        ("<3", "\u{2764}\u{FE0F}"),
        (":O", "\u{1F62E}")
    ]

    init() {}

    func filter(_ content: MessageContent, direction: FilterDirection, context: FilterContext) async -> MessageContent {
        guard direction == .outgoing else { return content }

        var body = content.body
        for (pattern, emoji) in Self.replacements {
            body = replaceEmoticon(in: body, pattern: pattern, emoji: emoji)
        }
        return MessageContent(body: body, htmlBody: content.htmlBody, detectedURLs: content.detectedURLs)
    }

    private func replaceEmoticon(in text: String, pattern: String, emoji: String) -> String {
        guard text.contains(pattern) else { return text }

        var result = ""
        var remaining = text[text.startIndex...]

        while let range = remaining.range(of: pattern) {
            let beforeIndex = range.lowerBound
            let afterIndex = range.upperBound

            let charBefore = beforeIndex > remaining.startIndex
                ? remaining[remaining.index(before: beforeIndex)]
                : nil
            let charAfter = afterIndex < remaining.endIndex
                ? remaining[afterIndex]
                : nil

            let boundaryBefore = charBefore == nil || charBefore == " " || charBefore == "\n"
            let boundaryAfter = charAfter == nil || charAfter == " " || charAfter == "\n"

            if boundaryBefore, boundaryAfter {
                result += remaining[remaining.startIndex ..< beforeIndex]
                result += emoji
            } else {
                result += remaining[remaining.startIndex ..< afterIndex]
            }
            remaining = remaining[afterIndex...]
        }
        result += remaining
        return result
    }
}
