import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let filterContext = FilterContext(
    accountJID: BareJID(localPart: "user", domainPart: "example.com")!
)

enum StylingFilterTests {
    struct IncomingTests {
        @Test
        func `styles incoming messages with bold`() async {
            let filter = StylingFilter()
            let content = MessageContent(body: "hello *world*")
            let result = await filter.filter(content, direction: .incoming, context: filterContext)
            #expect(result.htmlBody == "hello <strong>world</strong>")
        }

        @Test
        func `preserves original body`() async {
            let filter = StylingFilter()
            let content = MessageContent(body: "hello *world*")
            let result = await filter.filter(content, direction: .incoming, context: filterContext)
            #expect(result.body == "hello *world*")
        }

        @Test
        func `skips plain text without styling`() async {
            let filter = StylingFilter()
            let content = MessageContent(body: "just plain text")
            let result = await filter.filter(content, direction: .incoming, context: filterContext)
            #expect(result.htmlBody == nil)
        }

        @Test
        func `skips when isUnstyled is true`() async {
            let filter = StylingFilter()
            let content = MessageContent(body: "hello *world*", isUnstyled: true)
            let result = await filter.filter(content, direction: .incoming, context: filterContext)
            #expect(result.htmlBody == nil)
        }
    }

    struct OutgoingTests {
        @Test
        func `styles outgoing messages with bold`() async {
            let filter = StylingFilter()
            let content = MessageContent(body: "hello *world*")
            let result = await filter.filter(content, direction: .outgoing, context: filterContext)
            #expect(result.htmlBody == "hello <strong>world</strong>")
        }
    }

    struct PriorityTests {
        @Test
        func `priority is 5`() {
            let filter = StylingFilter()
            #expect(filter.priority == 5)
        }
    }
}
