import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let testAccountID = UUID()
private let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!
private let roomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

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

/// Extracts the first `id="..."` attribute value from a raw XML string.
/// `XMLElement.xmlString` writes attributes with double quotes sorted
/// alphabetically by key, so the outer iq's id always precedes any inner id.
///
/// Mirror of `Tests/DuckoXMPPTests/XMPPTestHelpers.swift` `extractIQID(from:)`.
/// Kept per-file private because DuckoCoreTests cannot reach DuckoXMPPTests
/// helpers; keep the two implementations in sync.
private func extractIQID(from xmlString: String) -> String? {
    guard let idRange = xmlString.range(of: "id=\""),
          let endRange = xmlString[idRange.upperBound...].firstIndex(of: "\"") else {
        return nil
    }
    return String(xmlString[idRange.upperBound ..< endRange])
}

// MARK: - Tests

enum ChatServiceRetractionTests {
    struct IncomingRetraction {
        @Test
        @MainActor
        func `message retraction marks retracted and clears body`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: testAccountID, jid: contactJID,
                type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            let message = ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "msg-to-retract",
                fromJID: contactJID.description, body: "Secret message",
                timestamp: Date(), isOutgoing: false,
                isDelivered: false, isEdited: false, type: "chat"
            )
            await transcripts.addMessage(message)

            let from = try #require(JID.parse("contact@example.com/res"))
            await service.handleEvent(
                .messageRetracted(originalID: "msg-to-retract", from: from),
                accountID: testAccountID
            )

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].isRetracted == true)
            #expect(messages[0].retractedAt != nil)
            let bodyIsEmpty = messages[0].body.isEmpty
            #expect(bodyIsEmpty)
        }
    }

    struct ModerateNilConversation {
        @Test
        @MainActor
        func `moderateMessage skips amendment when conversationID resolves to nil`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let transport = MockTransport()
            let factory = MockXMPPClientFactory(transport: transport, modules: [MUCModule()])
            let accountService = makeAccountService(store: store, clientFactory: factory)
            let chatService = makeChatService(store: store, transcripts: transcripts)
            chatService.setAccountService(accountService)

            let connectTask = Task { @MainActor in
                try await accountService.createAndConnect(
                    jidString: testJIDString, password: "secret",
                    host: "example.com", port: 5222
                )
            }
            await simulateNoTLSConnect(transport)
            let accountID = try await connectTask.value

            // Do NOT seed a conversation for roomJID — conversationID(for:)
            // returns nil and the amendment branch is skipped.
            let moderateTask = Task { @MainActor in
                try await chatService.moderateMessage(
                    serverID: "srv-1", in: roomJID, reason: nil, accountID: accountID
                )
            }

            await transport.waitForSent(count: 5) // 4 from connect + moderation IQ
            let sent = await transport.sentBytes
            let raw = try String(decoding: #require(sent.last), as: UTF8.self)
            let iqID = try #require(extractIQID(from: raw))
            await transport.simulateReceive(
                "<iq type=\"result\" id=\"\(iqID)\" from=\"\(roomJID.description)\"/>"
            )

            try await moderateTask.value

            let amendments = await transcripts.amendments
            #expect(amendments.isEmpty)
            #expect(chatService.openConversations.isEmpty)
            #expect(chatService.messages.isEmpty)

            await accountService.disconnect(accountID: accountID)
        }
    }

    struct IncomingModeration {
        @Test
        @MainActor
        func `message moderation marks retracted by server ID`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: testAccountID, jid: roomJID,
                type: .groupchat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            let message = ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "local-id",
                serverID: "server-stanza-id",
                fromJID: "alice", body: "Bad message",
                timestamp: Date(), isOutgoing: false,
                isDelivered: false, isEdited: false, type: "groupchat"
            )
            await transcripts.addMessage(message)

            await service.handleEvent(
                .messageModerated(
                    originalID: "server-stanza-id",
                    moderator: "admin",
                    room: roomJID,
                    reason: "Spam"
                ),
                accountID: testAccountID
            )

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].isRetracted == true)
            #expect(messages[0].retractedAt != nil)
            let bodyIsEmpty = messages[0].body.isEmpty
            #expect(bodyIsEmpty)
        }
    }
}
