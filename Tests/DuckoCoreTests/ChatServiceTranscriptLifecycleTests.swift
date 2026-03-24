import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let accountID = UUID()
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

private func makeConversation(id: UUID = UUID(), accountID: UUID, jid: String = "contact@example.com") -> Conversation {
    Conversation(
        id: id,
        accountID: accountID,
        jid: BareJID.parse(jid)!,
        type: .chat,
        isPinned: false,
        isMuted: false,
        unreadCount: 0,
        createdAt: Date()
    )
}

private func makeMessage(conversationID: UUID) -> ChatMessage {
    ChatMessage(
        id: UUID(),
        conversationID: conversationID,
        fromJID: contactJID.description,
        body: "Hello",
        timestamp: Date(),
        isOutgoing: false,
        isDelivered: false,
        isEdited: false,
        type: "chat"
    )
}

enum ChatServiceTranscriptLifecycleTests {
    @MainActor
    struct DeleteTranscriptsForAccount {
        @Test
        func `Deletes transcripts for all conversations under account`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let conv1 = makeConversation(accountID: accountID, jid: "alice@example.com")
            let conv2 = makeConversation(accountID: accountID, jid: "bob@example.com")
            await store.addConversation(conv1)
            await store.addConversation(conv2)

            await transcripts.addMessage(makeMessage(conversationID: conv1.id))
            await transcripts.addMessage(makeMessage(conversationID: conv2.id))

            try await service.deleteTranscriptsForAccount(accountID)

            let remaining1 = try await transcripts.fetchMessages(for: conv1.id, before: nil, limit: 100)
            let remaining2 = try await transcripts.fetchMessages(for: conv2.id, before: nil, limit: 100)
            #expect(remaining1.isEmpty)
            #expect(remaining2.isEmpty)
        }

        @Test
        func `Does not delete transcripts for other accounts`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let otherAccountID = UUID()
            let conv = makeConversation(accountID: accountID)
            let otherConv = makeConversation(accountID: otherAccountID, jid: "other@example.com")
            await store.addConversation(conv)
            await store.addConversation(otherConv)

            await transcripts.addMessage(makeMessage(conversationID: conv.id))
            await transcripts.addMessage(makeMessage(conversationID: otherConv.id))

            try await service.deleteTranscriptsForAccount(accountID)

            let remaining = try await transcripts.fetchMessages(for: otherConv.id, before: nil, limit: 100)
            #expect(remaining.count == 1)
        }

        @Test
        func `Succeeds when account has no conversations`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            try await service.deleteTranscriptsForAccount(accountID)
            // No error thrown
        }
    }
}
