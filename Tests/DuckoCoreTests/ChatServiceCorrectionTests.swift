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

@MainActor
private func makeChatService(store: MockPersistenceStore) -> ChatService {
    ChatService(store: store, filterPipeline: MessageFilterPipeline())
}

// MARK: - Tests

enum ChatServiceCorrectionTests {
    struct IncomingCorrection {
        @Test("Message correction updates body and marks edited")
        @MainActor
        func correctionUpdatesBody() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: testAccountID, jid: contactJID,
                type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            let message = ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "msg-original",
                fromJID: contactJID.description, body: "Original text",
                timestamp: Date(), isOutgoing: false, isRead: false,
                isDelivered: false, isEdited: false, type: "chat"
            )
            await store.addMessage(message)

            let from = try #require(JID.parse("contact@example.com/res"))
            await service.handleEvent(
                .messageCorrected(originalID: "msg-original", newBody: "Corrected text", from: from),
                accountID: testAccountID
            )

            let messages = try await store.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].body == "Corrected text")
            #expect(messages[0].isEdited == true)
            #expect(messages[0].editedAt != nil)
        }
    }
}
