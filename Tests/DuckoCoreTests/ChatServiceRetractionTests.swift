import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// MARK: - Helpers

private let testAccountID = UUID()
private let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!
private let roomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

private func makeStore() -> MockPersistenceStore {
    MockPersistenceStore()
}

@MainActor
private func makeChatService(store: MockPersistenceStore) -> ChatService {
    ChatService(store: store, filterPipeline: MessageFilterPipeline())
}

// MARK: - Tests

enum ChatServiceRetractionTests {
    struct IncomingRetraction {
        @Test
        @MainActor
        func `message retraction marks retracted and clears body`() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: testAccountID, jid: contactJID,
                type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            let message = ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "msg-to-retract",
                fromJID: contactJID.description, body: "Secret message",
                timestamp: Date(), isOutgoing: false, isRead: false,
                isDelivered: false, isEdited: false, type: "chat"
            )
            await store.addMessage(message)

            let from = try #require(JID.parse("contact@example.com/res"))
            await service.handleEvent(
                .messageRetracted(originalID: "msg-to-retract", from: from),
                accountID: testAccountID
            )

            let messages = try await store.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].isRetracted == true)
            #expect(messages[0].retractedAt != nil)
            let bodyIsEmpty = messages[0].body.isEmpty
            #expect(bodyIsEmpty)
        }
    }

    struct IncomingModeration {
        @Test
        @MainActor
        func `message moderation marks retracted by server ID`() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: testAccountID, jid: roomJID,
                type: .groupchat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            let message = ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "local-id",
                serverID: "server-stanza-id",
                fromJID: "alice", body: "Bad message",
                timestamp: Date(), isOutgoing: false, isRead: false,
                isDelivered: false, isEdited: false, type: "groupchat"
            )
            await store.addMessage(message)

            await service.handleEvent(
                .messageModerated(
                    originalID: "server-stanza-id",
                    moderator: "admin",
                    room: roomJID,
                    reason: "Spam"
                ),
                accountID: testAccountID
            )

            let messages = try await store.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].isRetracted == true)
            #expect(messages[0].retractedAt != nil)
            let bodyIsEmpty = messages[0].body.isEmpty
            #expect(bodyIsEmpty)
        }
    }
}
