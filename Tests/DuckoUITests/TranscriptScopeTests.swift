import DuckoCore
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoUI

@MainActor
struct TranscriptScopeTests {
    private static func conversation(
        id: UUID = UUID(),
        accountID: UUID,
        jid: String,
        type: Conversation.ConversationType,
        occupantNickname: String? = nil
    ) throws -> Conversation {
        try Conversation(
            id: id,
            accountID: accountID,
            jid: #require(BareJID.parse(jid)),
            type: type,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            occupantNickname: occupantNickname,
            createdAt: Date()
        )
    }

    @Test func `ref carrying conversationID matches by id alone`() throws {
        let account = UUID()
        let conv = try Self.conversation(accountID: account, jid: "bob@example.com", type: .chat)
        let ref = ConversationRef(conversation: conv)

        #expect(ref.matches(conv))
        // A different conversation with the same JID but a different id must not match.
        let other = try Self.conversation(accountID: account, jid: "bob@example.com", type: .chat)
        #expect(!ref.matches(other))
    }

    @Test func `a MUC PM ref resolves the PM, not the room`() throws {
        let account = UUID()
        let room = try Self.conversation(accountID: account, jid: "room@conf.example.com", type: .groupchat)
        let pm = try Self.conversation(
            accountID: account, jid: "room@conf.example.com", type: .chat, occupantNickname: "nick"
        )

        let pmRef = ConversationRef(conversation: pm)
        #expect(pmRef.matches(pm))
        #expect(!pmRef.matches(room))
    }

    @Test func `id-less ref falls back to the full identity tuple`() throws {
        let account = UUID()
        let pm = try Self.conversation(
            accountID: account, jid: "room@conf.example.com", type: .chat, occupantNickname: "nick"
        )
        let room = try Self.conversation(accountID: account, jid: "room@conf.example.com", type: .groupchat)

        // No conversationID known — the tuple (account + jid + type + nick) still distinguishes
        // the PM from the room despite sharing a bare JID.
        let ref = ConversationRef(
            accountID: account, jid: "room@conf.example.com", type: .chat, occupantNickname: "nick"
        )
        #expect(ref.matches(pm))
        #expect(!ref.matches(room))
    }

    @Test func `same bare JID on a different account does not match`() throws {
        let accountA = UUID()
        let accountB = UUID()
        let convA = try Self.conversation(accountID: accountA, jid: "bob@example.com", type: .chat)
        let convB = try Self.conversation(accountID: accountB, jid: "bob@example.com", type: .chat)

        let ref = ConversationRef(accountID: accountA, jid: "bob@example.com", type: .chat)
        #expect(ref.matches(convA))
        #expect(!ref.matches(convB))
    }

    @Test func `request bumps the generation monotonically`() {
        let scope = TranscriptScope()
        let ref = ConversationRef(jid: "bob@example.com", type: .chat)

        let first = scope.request(ref)
        let second = scope.request(ref)

        #expect(second.generation > first.generation)
        #expect(scope.requested?.generation == second.generation)
    }

    @Test func `clearHandled clears only the matching generation`() {
        let scope = TranscriptScope()
        let ref = ConversationRef(jid: "bob@example.com", type: .chat)

        let first = scope.request(ref)
        let second = scope.request(ref)

        // A stale handler for the first request must not clear the newer pending request.
        scope.clearHandled(first.generation)
        #expect(scope.requested?.generation == second.generation)

        // The handler for the current request clears it.
        scope.clearHandled(second.generation)
        #expect(scope.requested == nil)
    }
}
