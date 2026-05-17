import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let testAccountID = UUID()
private let testAccountJID = BareJID(localPart: "user", domainPart: "example.com")!
private let testRoomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

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
        @Test
        @MainActor
        func `roomJoined creates groupchat conversation`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let occupancy = RoomOccupancy(
                nickname: "me",
                occupants: [RoomOccupant(nickname: "me", affiliation: .member, role: .participant)],
                subject: nil
            )
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy, isNewlyCreated: false), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations.count == 1)
            #expect(conversations[0].jid == testRoomJID)
            #expect(conversations[0].type == .groupchat)
            #expect(conversations[0].roomNickname == "me")
        }
    }

    struct GroupMessagePersistence {
        @Test
        @MainActor
        func `roomMessageReceived persists incoming group message`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            // Create the group conversation first
            let occupancy = RoomOccupancy(nickname: "me", occupants: [], subject: nil)
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy, isNewlyCreated: false), accountID: testAccountID)

            // Receive a message from another occupant
            let xmppMessage = makeGroupMessage(from: testRoomJID, senderNickname: "other", body: "Hello room!")
            await service.handleEvent(.roomMessageReceived(xmppMessage), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            let messages = try await transcripts.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
            #expect(messages.count == 1)
            #expect(messages[0].body == "Hello room!")
            #expect(messages[0].type == "groupchat")
            #expect(messages[0].fromJID == "other")
            #expect(messages[0].isOutgoing == false)
        }

        @Test
        @MainActor
        func `Own groupchat echo is persisted without a wired-up client`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            // Create the group conversation
            let occupancy = RoomOccupancy(nickname: "me", occupants: [], subject: nil)
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy, isNewlyCreated: false), accountID: testAccountID)

            // Receive echo of own message — without an accountService/client wired up,
            // the MUCModule nickname lookup will fail, so the message will be persisted.
            // In integration tests with a real client, own messages would be skipped.
            let xmppMessage = makeGroupMessage(from: testRoomJID, senderNickname: "me", body: "My echo")
            await service.handleEvent(.roomMessageReceived(xmppMessage), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            let messages = try await transcripts.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
            #expect(messages.count == 1)
        }
    }

    struct SubjectChanged {
        @Test
        @MainActor
        func `roomSubjectChanged updates conversation`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            // Create the group conversation
            let occupancy = RoomOccupancy(nickname: "me", occupants: [], subject: nil)
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy, isNewlyCreated: false), accountID: testAccountID)

            await service.handleEvent(
                .roomSubjectChanged(room: testRoomJID, subject: "New topic", setter: nil),
                accountID: testAccountID
            )

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations[0].roomSubject == "New topic")
        }
    }

    struct ConversationReuse {
        @Test
        @MainActor
        func `Multiple events for same room reuse existing conversation`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            // Join creates conversation
            let occupancy = RoomOccupancy(nickname: "me", occupants: [], subject: nil)
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy, isNewlyCreated: false), accountID: testAccountID)

            // Receiving a message should reuse the same conversation
            let msg = makeGroupMessage(from: testRoomJID, senderNickname: "other", body: "Hi")
            await service.handleEvent(.roomMessageReceived(msg), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations.count == 1)

            let messages = try await transcripts.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
            #expect(messages.count == 1)
        }
    }

    /// Locks `clearRoomState`'s contract that all three per-room snapshots
    /// (`roomParticipants`, `roomFlags`, `newlyCreatedRoomJIDs`) drop together
    /// for one JID. Direct call covers the contract; `roomDestroyed` covers
    /// the wiring through `handleRoomDestroyed`. `leaveRoom`'s wiring is
    /// exercised transitively by `IntegrationTests` (it calls into
    /// `MUCModule.leaveRoom` which is not stubbed in unit tests).
    struct ClearRoomStateTests {
        @Test
        @MainActor
        func `clearRoomState drops all three room maps`() async {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let key = testRoomJID.description

            let occupancy = RoomOccupancy(
                nickname: "me",
                occupants: [RoomOccupant(nickname: "me", affiliation: .owner, role: .moderator)],
                subject: nil,
                flags: [.nonAnonymous, .logged]
            )
            await service.handleEvent(
                .roomJoined(room: testRoomJID, occupancy: occupancy, isNewlyCreated: true),
                accountID: testAccountID
            )

            #expect(service.roomParticipants[testRoomJID] != nil)
            #expect(service.roomFlags[key] != nil)
            #expect(service.newlyCreatedRoomJIDs.contains(key))

            service.clearRoomState(for: testRoomJID)

            #expect(service.roomParticipants[testRoomJID] == nil)
            #expect(service.roomFlags[key] == nil)
            #expect(!service.newlyCreatedRoomJIDs.contains(key))
        }

        @Test
        @MainActor
        func `roomDestroyed clears all three room maps`() async {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let key = testRoomJID.description

            let occupancy = RoomOccupancy(
                nickname: "me",
                occupants: [RoomOccupant(nickname: "me", affiliation: .owner, role: .moderator)],
                subject: nil,
                flags: [.nonAnonymous]
            )
            await service.handleEvent(
                .roomJoined(room: testRoomJID, occupancy: occupancy, isNewlyCreated: true),
                accountID: testAccountID
            )

            await service.handleEvent(
                .roomDestroyed(room: testRoomJID, reason: nil, alternateVenue: nil),
                accountID: testAccountID
            )

            #expect(service.roomParticipants[testRoomJID] == nil)
            #expect(service.roomFlags[key] == nil)
            #expect(!service.newlyCreatedRoomJIDs.contains(key))
        }

        @Test
        @MainActor
        func `disconnect clears all three room maps`() async {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let key = testRoomJID.description

            let occupancy = RoomOccupancy(
                nickname: "me",
                occupants: [RoomOccupant(nickname: "me", affiliation: .owner, role: .moderator)],
                subject: nil,
                flags: [.logged]
            )
            await service.handleEvent(
                .roomJoined(room: testRoomJID, occupancy: occupancy, isNewlyCreated: true),
                accountID: testAccountID
            )

            await service.handleEvent(.disconnected(.requested), accountID: testAccountID)

            #expect(service.roomParticipants[testRoomJID] == nil)
            #expect(service.roomFlags[key] == nil)
            #expect(!service.newlyCreatedRoomJIDs.contains(key))
        }

        /// Locks the per-account scope of the disconnect-time clear: when
        /// account A disconnects, only A's rooms drop from the in-memory
        /// maps; account B's rooms stay intact so the still-connected
        /// session keeps working. A regression that reintroduced the
        /// global `removeAll()` would silently erase B's state.
        @Test
        @MainActor
        func `disconnect clears only the disconnecting account's rooms`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let accountA = UUID()
            let accountB = UUID()
            let roomA = try #require(BareJID.parse("alpha@conference.example.com"))
            let roomB = try #require(BareJID.parse("beta@conference.example.com"))

            let occupancy = RoomOccupancy(
                nickname: "me",
                occupants: [RoomOccupant(nickname: "me", affiliation: .owner, role: .moderator)],
                subject: nil,
                flags: [.logged]
            )
            await service.handleEvent(
                .roomJoined(room: roomA, occupancy: occupancy, isNewlyCreated: true),
                accountID: accountA
            )
            await service.handleEvent(
                .roomJoined(room: roomB, occupancy: occupancy, isNewlyCreated: true),
                accountID: accountB
            )

            // Disconnect only account A.
            await service.handleEvent(.disconnected(.requested), accountID: accountA)

            // A's room state is gone.
            #expect(service.roomParticipants[roomA] == nil)
            #expect(service.roomFlags[roomA.description] == nil)
            #expect(!service.newlyCreatedRoomJIDs.contains(roomA.description))

            // B's room state is preserved.
            #expect(service.roomParticipants[roomB] != nil)
            #expect(service.roomFlags[roomB.description] != nil)
            #expect(service.newlyCreatedRoomJIDs.contains(roomB.description))
        }
    }
}
