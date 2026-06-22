import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCore

struct ConversationTests {
    private func conversation(jid: BareJID, displayName: String?) -> Conversation {
        Conversation(
            id: UUID(),
            jid: jid,
            type: .chat,
            displayName: displayName,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            createdAt: Date()
        )
    }

    @Test func `displayTitle prefers the explicit display name`() throws {
        let jid = try #require(BareJID(localPart: "bob", domainPart: "example.com"))
        #expect(conversation(jid: jid, displayName: "Bobby").displayTitle == "Bobby")
    }

    @Test func `displayTitle falls back to the JID local part`() throws {
        let jid = try #require(BareJID(localPart: "bob", domainPart: "example.com"))
        #expect(conversation(jid: jid, displayName: nil).displayTitle == "bob")
    }

    @Test func `displayTitle falls back to the full JID when there is no local part`() throws {
        let jid = try #require(BareJID(localPart: nil, domainPart: "conference.example.com"))
        let title = conversation(jid: jid, displayName: nil).displayTitle
        #expect(title == jid.description)
        #expect(title == "conference.example.com")
    }
}
