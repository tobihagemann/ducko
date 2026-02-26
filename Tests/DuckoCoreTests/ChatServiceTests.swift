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

@MainActor
private func makeChatService(store: MockPersistenceStore) -> ChatService {
    ChatService(store: store, filterPipeline: MessageFilterPipeline())
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
        @Test("Incoming message creates conversation and persists message")
        @MainActor
        func incomingMessageCreatesConversation() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            let xmppMessage = makeIncomingMessage(from: contactJID, body: "Hello!")
            await service.handleEvent(.messageReceived(xmppMessage), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations.count == 1)
            #expect(conversations[0].jid == contactJID)
            #expect(conversations[0].type == .chat)

            let messages = try await store.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
            #expect(messages.count == 1)
            #expect(messages[0].body == "Hello!")
            #expect(messages[0].isOutgoing == false)
            #expect(messages[0].isRead == false)
        }

        @Test("Incoming message upserts existing conversation")
        @MainActor
        func incomingMessageUpsertsConversation() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            // First message creates conversation
            let msg1 = makeIncomingMessage(from: contactJID, body: "First")
            await service.handleEvent(.messageReceived(msg1), accountID: testAccountID)

            // Second message should use same conversation
            let msg2 = makeIncomingMessage(from: contactJID, body: "Second")
            await service.handleEvent(.messageReceived(msg2), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations.count == 1)

            let messages = try await store.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
            #expect(messages.count == 2)
        }

        @Test("Duplicate stanza ID is ignored")
        @MainActor
        func duplicateStanzaIDIgnored() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            let msg1 = makeIncomingMessage(from: contactJID, body: "Hello!", id: "msg-1")
            await service.handleEvent(.messageReceived(msg1), accountID: testAccountID)

            // Load conversations so openConversations is populated for duplicate check
            try await service.loadConversations(for: testAccountID)

            // Same stanza ID should be ignored
            let msg2 = makeIncomingMessage(from: contactJID, body: "Hello!", id: "msg-1")
            await service.handleEvent(.messageReceived(msg2), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            let messages = try await store.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
            #expect(messages.count == 1)
        }

        @Test("Messages without body are ignored")
        @MainActor
        func messagesWithoutBodyIgnored() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            // Message with no body
            var xmppMessage = XMPPMessage(type: .chat, to: .bare(testAccountJID))
            xmppMessage.from = try .full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            await service.handleEvent(.messageReceived(xmppMessage), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations.isEmpty)
        }

        @Test("Non-chat messages are ignored")
        @MainActor
        func nonChatMessagesIgnored() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            var xmppMessage = XMPPMessage(type: .headline, to: .bare(testAccountJID))
            xmppMessage.from = try .full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            xmppMessage.body = "Headline"
            await service.handleEvent(.messageReceived(xmppMessage), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations.isEmpty)
        }
    }

    struct ConversationMetadata {
        @Test("Conversation metadata is updated on incoming message")
        @MainActor
        func conversationMetadataUpdated() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            let msg = makeIncomingMessage(from: contactJID, body: "Test message")
            await service.handleEvent(.messageReceived(msg), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations[0].lastMessagePreview == "Test message")
            #expect(conversations[0].lastMessageDate != nil)
            #expect(conversations[0].unreadCount == 1)
        }

        @Test("Unread count increments with each message")
        @MainActor
        func unreadCountIncrements() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            let msg1 = makeIncomingMessage(from: contactJID, body: "First")
            await service.handleEvent(.messageReceived(msg1), accountID: testAccountID)

            let msg2 = makeIncomingMessage(from: contactJID, body: "Second")
            await service.handleEvent(.messageReceived(msg2), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations[0].unreadCount == 2)
        }
    }

    struct NonMessageEvents {
        @Test("Non-message events are ignored")
        @MainActor
        func nonMessageEventsIgnored() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            let presence = XMPPPresence(type: nil)
            await service.handleEvent(.presenceReceived(presence), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations.isEmpty)
        }
    }

    struct FilterPipelineTests {
        @Test("Message content passes through filter pipeline")
        @MainActor
        func filterPipelineApplied() async throws {
            let store = makeStore()
            let pipeline = MessageFilterPipeline()
            await pipeline.register(UppercaseFilter())
            let service = ChatService(store: store, filterPipeline: pipeline)

            let msg = makeIncomingMessage(from: contactJID, body: "hello")
            await service.handleEvent(.messageReceived(msg), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            let messages = try await store.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
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
