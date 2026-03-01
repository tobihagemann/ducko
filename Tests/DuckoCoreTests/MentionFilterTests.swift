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
        @Test("Detects @mention and wraps in bold in htmlBody")
        func detectsMention() async {
            let filter = MentionFilter()
            let content = MessageContent(body: "Hey @user check this")
            let result = await filter.filter(content, direction: .incoming, context: filterContext)
            #expect(result.body == "Hey @user check this")
            #expect(result.htmlBody == "Hey <b>@user</b> check this")
        }

        @Test("No mention — no htmlBody added")
        func noMentionNoHtmlBody() async {
            let filter = MentionFilter()
            let content = MessageContent(body: "Just a normal message")
            let result = await filter.filter(content, direction: .incoming, context: filterContext)
            #expect(result.htmlBody == nil)
        }
    }

    struct OutgoingPassthrough {
        @Test("Does not process outgoing messages")
        func passthroughOnOutgoing() async {
            let filter = MentionFilter()
            let content = MessageContent(body: "Hey @user check this")
            let result = await filter.filter(content, direction: .outgoing, context: filterContext)
            #expect(result.htmlBody == nil)
        }
    }
}
