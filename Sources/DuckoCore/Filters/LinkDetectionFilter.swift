import Foundation

/// Detects URLs in message bodies using NSDataDetector and populates `detectedURLs`.
public struct LinkDetectionFilter: MessageFilter, Sendable {
    public let priority = 10

    public init() {}

    public func filter(_ content: MessageContent, direction: FilterDirection, context: FilterContext) async -> MessageContent {
        guard !content.body.isEmpty else { return content }

        let body = content.body
        let urls: [URL]
        do {
            let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let range = NSRange(body.startIndex..., in: body)
            let matches = detector.matches(in: body, range: range)
            urls = matches.compactMap(\.url)
        } catch {
            return content
        }

        guard !urls.isEmpty else { return content }

        return MessageContent(body: content.body, htmlBody: content.htmlBody, detectedURLs: urls)
    }
}
