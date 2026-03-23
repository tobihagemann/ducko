import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// MARK: - Helpers

private let testAccountID = UUID()
private let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!

@MainActor
private func makeChatService(store: MockPersistenceStore, transcripts: MockTranscriptStore) -> ChatService {
    ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
}

// MARK: - Tests

enum ChatServiceErrorTests {
    struct MessageError {
        @Test
        @MainActor
        func `Message error updates errorText`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = makeChatService(store: store, transcripts: transcripts)

            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: testAccountID, jid: contactJID,
                type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            let message = ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "msg-err-1",
                fromJID: contactJID.description, body: "Hello",
                timestamp: Date(), isOutgoing: true,
                isDelivered: false, isEdited: false, type: "chat"
            )
            await transcripts.addMessage(message)

            let from = try #require(JID.parse("contact@example.com/res"))
            let stanzaError = XMPPStanzaError(errorType: .cancel, condition: .serviceUnavailable)
            await service.handleEvent(
                .messageError(messageID: "msg-err-1", from: from, error: stanzaError),
                accountID: testAccountID
            )

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].errorText == "service-unavailable")
        }

        @Test
        @MainActor
        func `Message error without ID is ignored`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = makeChatService(store: store, transcripts: transcripts)

            let from = try #require(JID.parse("contact@example.com/res"))
            let stanzaError = XMPPStanzaError(errorType: .cancel, condition: .undefinedCondition, text: "error")
            await service.handleEvent(
                .messageError(messageID: nil, from: from, error: stanzaError),
                accountID: testAccountID
            )

            // No crash, no messages affected
            let messageCount = try await transcripts.fetchMessages(for: UUID(), before: nil, limit: 50).count
            #expect(messageCount == 0)
        }
    }
}
