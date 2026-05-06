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

/// Seeds a 1:1 conversation with `contactJID` plus one incoming message
/// stanza-id `msg-original`. Returns the conversation id so the test can
/// assert revision bumps without re-deriving it.
@MainActor
private func seedContactConversation(
    store: MockPersistenceStore, transcripts: MockTranscriptStore
) async -> UUID {
    let conversationID = UUID()
    await store.addConversation(Conversation(
        id: conversationID, accountID: testAccountID, jid: contactJID,
        type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
    ))
    await transcripts.addMessage(ChatMessage(
        id: UUID(), conversationID: conversationID, stanzaID: "msg-original",
        fromJID: contactJID.description, body: "Original text",
        timestamp: Date(), isOutgoing: false,
        isDelivered: false, isEdited: false, type: "chat"
    ))
    return conversationID
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
            let conversationID = await seedContactConversation(store: store, transcripts: transcripts)

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

        @Test
        @MainActor
        func `Correction bumps messagesRevisions for the affected conversation`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let conversationID = await seedContactConversation(store: store, transcripts: transcripts)

            // Conversation is NOT the active one — verifies the revision is
            // bumped for the *amended* conversation, not just the active one.
            // This is the load-bearing contract for `ChatWindow`s on
            // background conversations to refresh on incoming amendments.
            #expect(service.activeConversationID != conversationID)
            let beforeRevision = service.messagesRevisions[conversationID] ?? 0

            let from = try #require(JID.parse("contact@example.com/res"))
            await service.handleEvent(
                .messageCorrected(originalID: "msg-original", newBody: "Corrected text", from: from),
                accountID: testAccountID
            )

            let afterRevision = service.messagesRevisions[conversationID] ?? 0
            #expect(afterRevision > beforeRevision)
        }

        @Test
        @MainActor
        func `Retraction bumps messagesRevisions for the affected conversation`() async throws {
            // Parallel coverage to the correction case: the same `messagesChanged(in:)`
            // bridge is used by `handleMessageRetracted`, so a regression there
            // would silently break background-window refresh for retract events
            // unless this assertion is locked in independently.
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let conversationID = await seedContactConversation(store: store, transcripts: transcripts)

            #expect(service.activeConversationID != conversationID)
            let beforeRevision = service.messagesRevisions[conversationID] ?? 0

            let from = try #require(JID.parse("contact@example.com/res"))
            await service.handleEvent(
                .messageRetracted(originalID: "msg-original", from: from),
                accountID: testAccountID
            )

            let afterRevision = service.messagesRevisions[conversationID] ?? 0
            #expect(afterRevision > beforeRevision)
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
