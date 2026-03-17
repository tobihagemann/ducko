import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// MARK: - Helpers

private let testAccountID = UUID()
private let roomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

private func makeStore() -> MockPersistenceStore {
    MockPersistenceStore()
}

@MainActor
private func makeChatService(store: MockPersistenceStore) -> ChatService {
    ChatService(store: store, filterPipeline: MessageFilterPipeline())
}

private func seedGroupchatMessage(store: MockPersistenceStore) async -> UUID {
    let conversationID = UUID()
    await store.addConversation(Conversation(
        id: conversationID, accountID: testAccountID, jid: roomJID,
        type: .groupchat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
    ))
    let message = ChatMessage(
        id: UUID(), conversationID: conversationID, stanzaID: "msg-original",
        fromJID: "alice", body: "Original text",
        timestamp: Date(), isOutgoing: false, isRead: false,
        isDelivered: false, isEdited: false, type: "groupchat"
    )
    await store.addMessage(message)
    return conversationID
}

// MARK: - Tests

enum ChatServiceMUCCorrectionTests {
    struct IncomingCorrection {
        @Test
        @MainActor
        func `MUC correction updates body when nickname matches`() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)
            let conversationID = await seedGroupchatMessage(store: store)

            let from = try #require(JID.parse("room@conference.example.com/alice"))
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

    struct SenderVerification {
        @Test
        @MainActor
        func `MUC correction rejected when nickname does not match`() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)
            let conversationID = await seedGroupchatMessage(store: store)

            let attacker = try #require(JID.parse("room@conference.example.com/bob"))
            await service.handleEvent(
                .messageCorrected(originalID: "msg-original", newBody: "Hacked text", from: attacker),
                accountID: testAccountID
            )

            let messages = try await store.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].body == "Original text")
            #expect(messages[0].isEdited == false)
        }

        @Test
        @MainActor
        func `MUC correction rejected when from is bare JID`() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)
            let conversationID = await seedGroupchatMessage(store: store)

            let bareFrom = JID.bare(roomJID)
            await service.handleEvent(
                .messageCorrected(originalID: "msg-original", newBody: "Spoofed text", from: bareFrom),
                accountID: testAccountID
            )

            let messages = try await store.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].body == "Original text")
            #expect(messages[0].isEdited == false)
        }
    }
}
