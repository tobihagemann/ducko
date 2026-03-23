import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// MARK: - Helpers

private let testAccountID = UUID()
private let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!

private func makeStore() -> MockPersistenceStore {
    MockPersistenceStore()
}

private func makeTranscripts() -> MockTranscriptStore {
    MockTranscriptStore()
}

@MainActor
private func makeChatService(store: MockPersistenceStore, transcripts: MockTranscriptStore) -> ChatService {
    ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
}

// MARK: - Tests

enum ChatServiceCorrectionTests {
    struct IncomingCorrection {
        @Test
        @MainActor
        func `Message correction updates body and marks edited`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: testAccountID, jid: contactJID,
                type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            let message = ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "msg-original",
                fromJID: contactJID.description, body: "Original text",
                timestamp: Date(), isOutgoing: false,
                isDelivered: false, isEdited: false, type: "chat"
            )
            await transcripts.addMessage(message)

            let from = try #require(JID.parse("contact@example.com/res"))
            await service.handleEvent(
                .messageCorrected(originalID: "msg-original", newBody: "Corrected text", from: from),
                accountID: testAccountID
            )

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].body == "Corrected text")
            #expect(messages[0].isEdited == true)
            #expect(messages[0].editedAt != nil)
        }
    }

    struct SenderVerification {
        @Test
        @MainActor
        func `Correction rejected when sender does not match`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: testAccountID, jid: contactJID,
                type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            let message = ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "msg-original",
                fromJID: contactJID.description, body: "Original text",
                timestamp: Date(), isOutgoing: false,
                isDelivered: false, isEdited: false, type: "chat"
            )
            await transcripts.addMessage(message)

            let attacker = try #require(JID.parse("attacker@evil.com/res"))
            await service.handleEvent(
                .messageCorrected(originalID: "msg-original", newBody: "Hacked text", from: attacker),
                accountID: testAccountID
            )

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].body == "Original text")
            #expect(messages[0].isEdited == false)
            #expect(messages[0].editedAt == nil)
        }
    }
}
