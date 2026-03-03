import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCore

private let testContext = FilterContext(
    conversationJID: BareJID.parse("friend@example.com")!,
    accountJID: BareJID.parse("user@example.com")!
)

enum LinkDetectionFilterTests {
    struct DetectsHTTPURL {
        @Test("Detects a single HTTP URL in body")
        func detectsSingleURL() async {
            let filter = LinkDetectionFilter()
            let content = MessageContent(body: "Check out https://example.com/page")
            let result = await filter.filter(content, direction: .incoming, context: testContext)
            #expect(result.detectedURLs.count == 1)
            #expect(result.detectedURLs[0].absoluteString == "https://example.com/page")
        }
    }

    struct DetectsMultipleURLs {
        @Test("Detects multiple URLs in body")
        func detectsMultipleURLs() async {
            let filter = LinkDetectionFilter()
            let content = MessageContent(body: "Visit https://example.com and http://test.org/path")
            let result = await filter.filter(content, direction: .incoming, context: testContext)
            #expect(result.detectedURLs.count == 2)
        }
    }

    struct NoURLs {
        @Test("Returns empty detectedURLs for plain text")
        func noURLs() async {
            let filter = LinkDetectionFilter()
            let content = MessageContent(body: "Hello, how are you?")
            let result = await filter.filter(content, direction: .incoming, context: testContext)
            #expect(result.detectedURLs.isEmpty)
        }
    }

    struct PreservesBody {
        @Test("Body text is unchanged after filtering")
        func preservesBody() async {
            let filter = LinkDetectionFilter()
            let body = "Check https://example.com please"
            let content = MessageContent(body: body)
            let result = await filter.filter(content, direction: .incoming, context: testContext)
            #expect(result.body == body)
        }
    }
}
