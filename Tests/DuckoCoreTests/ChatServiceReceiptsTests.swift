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

enum ChatServiceReceiptsTests {
    struct DeliveryReceipt {
        @Test("Delivery receipt updates isDelivered")
        @MainActor
        func deliveryReceiptUpdatesStatus() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: testAccountID, jid: contactJID,
                type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            let message = ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "outgoing-1",
                fromJID: contactJID.description, body: "Hello",
                timestamp: Date(), isOutgoing: true, isRead: true,
                isDelivered: false, isEdited: false, type: "chat"
            )
            await store.addMessage(message)

            let from = try #require(JID.parse("contact@example.com/res"))
            await service.handleEvent(
                .deliveryReceiptReceived(messageID: "outgoing-1", from: from),
                accountID: testAccountID
            )

            let messages = try await store.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].isDelivered == true)
        }
    }

    struct ChatMarker {
        @Test("Displayed chat marker updates isDelivered")
        @MainActor
        func displayedMarkerUpdatesStatus() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: testAccountID, jid: contactJID,
                type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            let message = ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "outgoing-2",
                fromJID: contactJID.description, body: "Hi",
                timestamp: Date(), isOutgoing: true, isRead: true,
                isDelivered: false, isEdited: false, type: "chat"
            )
            await store.addMessage(message)

            let from = try #require(JID.parse("contact@example.com/res"))
            await service.handleEvent(
                .chatMarkerReceived(messageID: "outgoing-2", type: .displayed, from: from),
                accountID: testAccountID
            )

            let messages = try await store.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].isDelivered == true)
        }
    }
}
