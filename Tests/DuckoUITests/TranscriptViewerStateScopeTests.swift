import DuckoCore
import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoUI

@MainActor
struct TranscriptViewerStateScopeTests {
    private struct Fixture {
        let state: TranscriptViewerState
        let store: MockPersistenceStore
        let transcripts: MockTranscriptStore
    }

    private static func makeFixture() async throws -> Fixture {
        let store = MockPersistenceStore()
        let transcripts = MockTranscriptStore()
        let environment = AppEnvironment(
            store: store,
            transcripts: transcripts,
            credentialStore: NullCredentialStore()
        )
        return Fixture(
            state: TranscriptViewerState(environment: environment),
            store: store,
            transcripts: transcripts
        )
    }

    private static func conversation(id: UUID = UUID(), accountID: UUID, jid: String) throws -> Conversation {
        try Conversation(
            id: id,
            accountID: accountID,
            jid: #require(BareJID.parse(jid)),
            type: .chat,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            createdAt: Date()
        )
    }

    private static func message(conversationID: UUID, body: String, timestamp: Date) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            conversationID: conversationID,
            fromJID: "bob@example.com",
            body: body,
            timestamp: timestamp,
            isOutgoing: false,
            isDelivered: true,
            isEdited: false,
            type: "chat"
        )
    }

    @Test func `applyScope resolves by conversation id and loads the latest day's messages`() async throws {
        let fixture = try await Self.makeFixture()
        let conv = try Self.conversation(accountID: UUID(), jid: "bob@example.com")
        await fixture.store.addConversation(conv)
        await fixture.transcripts.addMessage(Self.message(conversationID: conv.id, body: "hi", timestamp: Date()))

        let request = TranscriptScope().request(ConversationRef(conversation: conv))
        await fixture.state.applyScope(request)

        #expect(fixture.state.selectedConversation?.id == conv.id)
        #expect(fixture.state.selectedDate != nil)
        #expect(fixture.state.messages.count == 1)
    }

    @Test func `applyScope refreshes the conversation list so a conversation created after load still resolves`() async throws {
        let fixture = try await Self.makeFixture()
        // The viewer opened with no conversations (load() ran before this chat existed),
        // so allConversations is empty — the History re-scope path must refresh first.
        #expect(fixture.state.allConversations.isEmpty)

        let conv = try Self.conversation(accountID: UUID(), jid: "carol@example.com")
        await fixture.store.addConversation(conv)
        await fixture.transcripts.addMessage(Self.message(conversationID: conv.id, body: "later", timestamp: Date()))

        let request = TranscriptScope().request(ConversationRef(conversation: conv))
        await fixture.state.applyScope(request)

        #expect(fixture.state.selectedConversation?.id == conv.id)
        #expect(fixture.state.messages.count == 1)
    }

    @Test func `applyScope leaves selection unchanged when no conversation matches`() async throws {
        let fixture = try await Self.makeFixture()
        let present = try Self.conversation(accountID: UUID(), jid: "bob@example.com")
        await fixture.store.addConversation(present)

        // Request a different conversation that the store never knows about.
        let absent = try Self.conversation(accountID: UUID(), jid: "ghost@example.com")
        let request = TranscriptScope().request(ConversationRef(conversation: absent))
        await fixture.state.applyScope(request)

        #expect(fixture.state.selectedConversation == nil)
        #expect(fixture.state.messages.isEmpty)
    }
}
