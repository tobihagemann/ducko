import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// MARK: - Helpers

private let testAccountID = UUID()
private let testAccountJID = BareJID(localPart: "user", domainPart: "example.com")!
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

private func makeIncomingMessage(
    from jid: BareJID,
    body: String,
    id: String? = nil
) -> XMPPMessage {
    var message = XMPPMessage(
        type: .chat,
        to: .bare(testAccountJID),
        id: id
    )
    message.from = .full(FullJID(bareJID: jid, resourcePart: "res")!)
    message.body = body
    return message
}

// MARK: - Tests

enum ChatServiceTests {
    struct IncomingMessages {
        @Test
        @MainActor
        func `Incoming message creates conversation and persists message`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let xmppMessage = makeIncomingMessage(from: contactJID, body: "Hello!")
            await service.handleEvent(.messageReceived(xmppMessage), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations.count == 1)
            #expect(conversations[0].jid == contactJID)
            #expect(conversations[0].type == .chat)

            let messages = try await transcripts.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
            #expect(messages.count == 1)
            #expect(messages[0].body == "Hello!")
            #expect(messages[0].isOutgoing == false)
        }

        @Test
        @MainActor
        func `Incoming message upserts existing conversation`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            // First message creates conversation
            let msg1 = makeIncomingMessage(from: contactJID, body: "First")
            await service.handleEvent(.messageReceived(msg1), accountID: testAccountID)

            // Second message should use same conversation
            let msg2 = makeIncomingMessage(from: contactJID, body: "Second")
            await service.handleEvent(.messageReceived(msg2), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations.count == 1)

            let messages = try await transcripts.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
            #expect(messages.count == 2)
        }

        @Test
        @MainActor
        func `Duplicate stanza ID is ignored`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let msg1 = makeIncomingMessage(from: contactJID, body: "Hello!", id: "msg-1")
            await service.handleEvent(.messageReceived(msg1), accountID: testAccountID)

            // Load conversations so openConversations is populated for duplicate check
            try await service.loadConversations(for: testAccountID)

            // Same stanza ID should be ignored
            let msg2 = makeIncomingMessage(from: contactJID, body: "Hello!", id: "msg-1")
            await service.handleEvent(.messageReceived(msg2), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            let messages = try await transcripts.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
            #expect(messages.count == 1)
        }

        @Test
        @MainActor
        func `Messages without body are ignored`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            // Message with no body
            var xmppMessage = XMPPMessage(type: .chat, to: .bare(testAccountJID))
            xmppMessage.from = try .full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            await service.handleEvent(.messageReceived(xmppMessage), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations.isEmpty)
        }

        @Test
        @MainActor
        func `Non-chat messages are ignored`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            var xmppMessage = XMPPMessage(type: .headline, to: .bare(testAccountJID))
            xmppMessage.from = try .full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            xmppMessage.body = "Headline"
            await service.handleEvent(.messageReceived(xmppMessage), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations.isEmpty)
        }
    }

    struct ConversationMetadata {
        @Test
        @MainActor
        func `Conversation metadata is updated on incoming message`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let msg = makeIncomingMessage(from: contactJID, body: "Test message")
            await service.handleEvent(.messageReceived(msg), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations[0].lastMessagePreview == "Test message")
            #expect(conversations[0].lastMessageDate != nil)
            #expect(conversations[0].unreadCount == 1)
        }

        @Test
        @MainActor
        func `Unread count increments with each message`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let msg1 = makeIncomingMessage(from: contactJID, body: "First")
            await service.handleEvent(.messageReceived(msg1), accountID: testAccountID)

            let msg2 = makeIncomingMessage(from: contactJID, body: "Second")
            await service.handleEvent(.messageReceived(msg2), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations[0].unreadCount == 2)
        }
    }

    struct NonMessageEvents {
        @Test
        @MainActor
        func `Non-message events are ignored`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let presence = XMPPPresence(type: nil)
            await service.handleEvent(.presenceReceived(presence), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations.isEmpty)
        }
    }

    struct OpenConversation {
        @Test
        @MainActor
        func `openConversation creates and returns conversation`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let conversation = try await service.openConversation(for: contactJID, accountID: testAccountID)

            #expect(conversation.jid == contactJID)
            #expect(conversation.accountID == testAccountID)
            #expect(service.openConversations.count == 1)
        }

        @Test
        @MainActor
        func `openConversation returns existing conversation`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let first = try await service.openConversation(for: contactJID, accountID: testAccountID)
            let second = try await service.openConversation(for: contactJID, accountID: testAccountID)

            #expect(first.id == second.id)
            #expect(service.openConversations.count == 1)
        }
    }

    struct LoadMessages {
        @Test
        @MainActor
        func `loadMessages returns messages in chronological order`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            // Create messages via incoming events
            let msg1 = makeIncomingMessage(from: contactJID, body: "First")
            await service.handleEvent(.messageReceived(msg1), accountID: testAccountID)
            let msg2 = makeIncomingMessage(from: contactJID, body: "Second")
            await service.handleEvent(.messageReceived(msg2), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            let messages = await service.loadMessages(for: conversations[0].id)

            #expect(messages.count == 2)
            #expect(messages[0].body == "First")
            #expect(messages[1].body == "Second")
        }
    }

    struct FilterPipelineTests {
        @Test
        @MainActor
        func `Message content passes through filter pipeline`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let pipeline = MessageFilterPipeline()
            await pipeline.register(UppercaseFilter())
            let service = ChatService(store: store, transcripts: transcripts, filterPipeline: pipeline)

            let msg = makeIncomingMessage(from: contactJID, body: "hello")
            await service.handleEvent(.messageReceived(msg), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            let messages = try await transcripts.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
            #expect(messages[0].body == "HELLO")
        }
    }
}

// MARK: - Test Filter

private struct UppercaseFilter: MessageFilter {
    let priority = 0

    func filter(_ content: MessageContent, direction: FilterDirection, context: FilterContext) async -> MessageContent {
        MessageContent(body: content.body.uppercased(), htmlBody: content.htmlBody)
    }
}
