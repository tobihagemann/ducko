import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// MARK: - Helpers

private let filterContext = FilterContext(
    conversationJID: BareJID(localPart: "contact", domainPart: "example.com")!,
    accountJID: BareJID(localPart: "user", domainPart: "example.com")!
)

// MARK: - Tests

enum EmojiFilterTests {
    struct OutgoingReplacement {
        @Test("Replaces :) with emoji on outgoing")
        func replacesSmile() async {
            let filter = EmojiFilter()
            let content = MessageContent(body: "Hello :)")
            let result = await filter.filter(content, direction: .outgoing, context: filterContext)
            #expect(result.body == "Hello \u{1F60A}")
        }

        @Test("Replaces :( with emoji on outgoing")
        func replacesSad() async {
            let filter = EmojiFilter()
            let content = MessageContent(body: "Oh no :(")
            let result = await filter.filter(content, direction: .outgoing, context: filterContext)
            #expect(result.body == "Oh no \u{1F61E}")
        }

        @Test("Replaces <3 with emoji on outgoing")
        func replacesHeart() async {
            let filter = EmojiFilter()
            let content = MessageContent(body: "Love <3")
            let result = await filter.filter(content, direction: .outgoing, context: filterContext)
            #expect(result.body == "Love \u{2764}\u{FE0F}")
        }

        @Test("Multiple emoticons in one message")
        func replacesMultiple() async {
            let filter = EmojiFilter()
            let content = MessageContent(body: ":) and :D")
            let result = await filter.filter(content, direction: .outgoing, context: filterContext)
            #expect(result.body == "\u{1F60A} and \u{1F604}")
        }
    }

    struct IncomingPassthrough {
        @Test("Does not replace emoticons on incoming")
        func passthroughOnIncoming() async {
            let filter = EmojiFilter()
            let content = MessageContent(body: "Hello :)")
            let result = await filter.filter(content, direction: .incoming, context: filterContext)
            #expect(result.body == "Hello :)")
        }
    }

    struct BoundaryAwareness {
        @Test("Does not replace emoticons inside words")
        func noReplacementInWords() async {
            let filter = EmojiFilter()
            let content = MessageContent(body: "http://example.com:)")
            let result = await filter.filter(content, direction: .outgoing, context: filterContext)
            #expect(result.body == "http://example.com:)")
        }
    }
}
