/// Detects @mentions of the account JID's local part in incoming messages
/// and wraps them in bold tags in htmlBody for visual highlighting.
struct MentionFilter: MessageFilter {
    let priority = 50

    init() {}

    func filter(_ content: MessageContent, direction: FilterDirection, context: FilterContext) async -> MessageContent {
        guard direction == .incoming else { return content }
        guard let localPart = context.accountJID.localPart else { return content }

        let mention = "@\(localPart)"
        guard content.body.contains(mention) else { return content }

        let htmlBody = content.htmlBody ?? content.body
        let highlightedHTML = htmlBody.replacingOccurrences(of: mention, with: "<b>\(mention)</b>")

        return MessageContent(body: content.body, htmlBody: highlightedHTML, detectedURLs: content.detectedURLs)
    }
}
