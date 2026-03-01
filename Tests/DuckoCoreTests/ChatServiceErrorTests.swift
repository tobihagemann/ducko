import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// MARK: - Helpers

private let testAccountID = UUID()
private let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!

@MainActor
private func makeChatService(store: MockPersistenceStore) -> ChatService {
    ChatService(store: store, filterPipeline: MessageFilterPipeline())
}

// MARK: - Tests

enum ChatServiceErrorTests {
    struct MessageError {
        @Test("Message error updates errorText")
        @MainActor
        func messageErrorUpdatesErrorText() async throws {
            let store = MockPersistenceStore()
            let service = makeChatService(store: store)

            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: testAccountID, jid: contactJID,
                type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            let message = ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "msg-err-1",
                fromJID: contactJID.description, body: "Hello",
                timestamp: Date(), isOutgoing: true, isRead: true,
                isDelivered: false, isEdited: false, type: "chat"
            )
            await store.addMessage(message)

            let from = try #require(JID.parse("contact@example.com/res"))
            await service.handleEvent(
                .messageError(messageID: "msg-err-1", from: from, errorText: "service-unavailable"),
                accountID: testAccountID
            )

            let messages = try await store.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].errorText == "service-unavailable")
        }

        @Test("Message error without ID is ignored")
        @MainActor
        func messageErrorWithoutIDIgnored() async throws {
            let store = MockPersistenceStore()
            let service = makeChatService(store: store)

            let from = try #require(JID.parse("contact@example.com/res"))
            await service.handleEvent(
                .messageError(messageID: nil, from: from, errorText: "error"),
                accountID: testAccountID
            )

            // No crash, no messages affected
            let messageCount = try await store.fetchMessages(for: UUID(), before: nil, limit: 50).count
            #expect(messageCount == 0)
        }
    }
}
