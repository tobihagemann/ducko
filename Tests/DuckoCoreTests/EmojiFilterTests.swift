import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let filterContext = FilterContext(
    accountJID: BareJID(localPart: "user", domainPart: "example.com")!
)

// MARK: - Tests

enum EmojiFilterTests {
    struct OutgoingReplacement {
        @Test
        func `Replaces :) with emoji on outgoing`() async {
            let filter = EmojiFilter()
            let content = MessageContent(body: "Hello :)")
            let result = await filter.filter(content, direction: .outgoing, context: filterContext)
            #expect(result.body == "Hello \u{1F60A}")
        }

        @Test
        func `Replaces :( with emoji on outgoing`() async {
            let filter = EmojiFilter()
            let content = MessageContent(body: "Oh no :(")
            let result = await filter.filter(content, direction: .outgoing, context: filterContext)
            #expect(result.body == "Oh no \u{1F61E}")
        }

        @Test
        func `Replaces <3 with emoji on outgoing`() async {
            let filter = EmojiFilter()
            let content = MessageContent(body: "Love <3")
            let result = await filter.filter(content, direction: .outgoing, context: filterContext)
            #expect(result.body == "Love \u{2764}\u{FE0F}")
        }

        @Test
        func `Multiple emoticons in one message`() async {
            let filter = EmojiFilter()
            let content = MessageContent(body: ":) and :D")
            let result = await filter.filter(content, direction: .outgoing, context: filterContext)
            #expect(result.body == "\u{1F60A} and \u{1F604}")
        }
    }

    struct IncomingPassthrough {
        @Test
        func `Does not replace emoticons on incoming`() async {
            let filter = EmojiFilter()
            let content = MessageContent(body: "Hello :)")
            let result = await filter.filter(content, direction: .incoming, context: filterContext)
            #expect(result.body == "Hello :)")
        }
    }

    struct BodyMutationGate {
        @Test
        func `Leaves the body unchanged when allowBodyMutation is false`() async throws {
            let filter = EmojiFilter()
            let context = try FilterContext(
                accountJID: #require(BareJID(localPart: "user", domainPart: "example.com")),
                allowBodyMutation: false
            )
            let content = MessageContent(body: "Hello :)")
            let result = await filter.filter(content, direction: .outgoing, context: context)
            // The archive/backfill path passes allowBodyMutation: false so stored bodies stay the server text.
            #expect(result.body == "Hello :)")
        }
    }

    struct BoundaryAwareness {
        @Test
        func `Does not replace emoticons inside words`() async {
            let filter = EmojiFilter()
            let content = MessageContent(body: "http://example.com:)")
            let result = await filter.filter(content, direction: .outgoing, context: filterContext)
            #expect(result.body == "http://example.com:)")
        }
    }
}
