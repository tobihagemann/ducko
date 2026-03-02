import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// MARK: - Helpers

private let testAccountID = UUID()
private let testAccountJID = BareJID(localPart: "user", domainPart: "example.com")!
private let testRoomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

private func makeStore() -> MockPersistenceStore {
    MockPersistenceStore()
}

@MainActor
private func makeChatService(store: MockPersistenceStore) -> ChatService {
    ChatService(store: store, filterPipeline: MessageFilterPipeline())
}

private func makeGroupMessage(
    from roomJID: BareJID,
    senderNickname: String,
    body: String,
    id: String? = nil
) -> XMPPMessage {
    let fullJID = FullJID(bareJID: roomJID, resourcePart: senderNickname)!
    var message = XMPPMessage(type: .groupchat, to: .bare(testAccountJID), id: id)
    message.from = .full(fullJID)
    message.body = body
    return message
}

// MARK: - Tests

enum ChatServiceMUCTests {
    struct RoomJoined {
        @Test("roomJoined creates groupchat conversation")
        @MainActor
        func roomJoinedCreatesConversation() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            let occupancy = RoomOccupancy(
                room: testRoomJID,
                nickname: "me",
                occupants: [RoomOccupant(nickname: "me", affiliation: .member, role: .participant)],
                subject: nil
            )
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations.count == 1)
            #expect(conversations[0].jid == testRoomJID)
            #expect(conversations[0].type == .groupchat)
            #expect(conversations[0].roomNickname == "me")
        }
    }

    struct GroupMessagePersistence {
        @Test("roomMessageReceived persists incoming group message")
        @MainActor
        func incomingGroupMessagePersisted() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            // Create the group conversation first
            let occupancy = RoomOccupancy(room: testRoomJID, nickname: "me", occupants: [], subject: nil)
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy), accountID: testAccountID)

            // Receive a message from another occupant
            let xmppMessage = makeGroupMessage(from: testRoomJID, senderNickname: "other", body: "Hello room!")
            await service.handleEvent(.roomMessageReceived(xmppMessage), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            let messages = try await store.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
            #expect(messages.count == 1)
            #expect(messages[0].body == "Hello room!")
            #expect(messages[0].type == "groupchat")
            #expect(messages[0].fromJID == "other")
            #expect(messages[0].isOutgoing == false)
        }

        @Test("Own groupchat echo is persisted without a wired-up client")
        @MainActor
        func ownGroupMessagePersistedWithoutClient() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            // Create the group conversation
            let occupancy = RoomOccupancy(room: testRoomJID, nickname: "me", occupants: [], subject: nil)
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy), accountID: testAccountID)

            // Receive echo of own message — without an accountService/client wired up,
            // the MUCModule nickname lookup will fail, so the message will be persisted.
            // In integration tests with a real client, own messages would be skipped.
            let xmppMessage = makeGroupMessage(from: testRoomJID, senderNickname: "me", body: "My echo")
            await service.handleEvent(.roomMessageReceived(xmppMessage), accountID: testAccountID)

            // Without a wired-up client, the message is persisted (expected for unit test scope)
            let conversations = try await store.fetchConversations(for: testAccountID)
            let messages = try await store.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
            #expect(messages.count == 1)
        }
    }

    struct SubjectChanged {
        @Test("roomSubjectChanged updates conversation")
        @MainActor
        func subjectUpdatesConversation() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            // Create the group conversation
            let occupancy = RoomOccupancy(room: testRoomJID, nickname: "me", occupants: [], subject: nil)
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy), accountID: testAccountID)

            await service.handleEvent(
                .roomSubjectChanged(room: testRoomJID, subject: "New topic", setter: nil),
                accountID: testAccountID
            )

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations[0].roomSubject == "New topic")
        }
    }

    struct ConversationReuse {
        @Test("Multiple events for same room reuse existing conversation")
        @MainActor
        func reuseExistingConversation() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            // Join creates conversation
            let occupancy = RoomOccupancy(room: testRoomJID, nickname: "me", occupants: [], subject: nil)
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy), accountID: testAccountID)

            // Receiving a message should reuse the same conversation
            let msg = makeGroupMessage(from: testRoomJID, senderNickname: "other", body: "Hi")
            await service.handleEvent(.roomMessageReceived(msg), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations.count == 1)

            let messages = try await store.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
            #expect(messages.count == 1)
        }
    }
}
