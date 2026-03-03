import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// MARK: - Helpers

private let filterContext = FilterContext(
    conversationJID: BareJID(localPart: "contact", domainPart: "example.com")!,
    accountJID: BareJID(localPart: "user", domainPart: "example.com")!
)

// MARK: - Tests

enum MentionFilterTests {
    struct IncomingMention {
        @Test
        func `Detects @mention and wraps in bold in htmlBody`() async {
            let filter = MentionFilter()
            let content = MessageContent(body: "Hey @user check this")
            let result = await filter.filter(content, direction: .incoming, context: filterContext)
            #expect(result.body == "Hey @user check this")
            #expect(result.htmlBody == "Hey <b>@user</b> check this")
        }

        @Test
        func `No mention — no htmlBody added`() async {
            let filter = MentionFilter()
            let content = MessageContent(body: "Just a normal message")
            let result = await filter.filter(content, direction: .incoming, context: filterContext)
            #expect(result.htmlBody == nil)
        }
    }

    struct OutgoingPassthrough {
        @Test
        func `Does not process outgoing messages`() async {
            let filter = MentionFilter()
            let content = MessageContent(body: "Hey @user check this")
            let result = await filter.filter(content, direction: .outgoing, context: filterContext)
            #expect(result.htmlBody == nil)
        }
    }
}
