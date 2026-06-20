import DuckoTestSupport
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

            #expect(!service.participants(forRoomJIDString: key, accountID: testAccountID).isEmpty)
            #expect(!service.roomFlags(forRoomJIDString: key, accountID: testAccountID).isEmpty)
            #expect(service.isRoomNewlyCreated(jidString: key, accountID: testAccountID))

            service.clearRoomState(for: testRoomJID, accountID: testAccountID)

            #expect(service.participants(forRoomJIDString: key, accountID: testAccountID).isEmpty)
            #expect(service.roomFlags(forRoomJIDString: key, accountID: testAccountID).isEmpty)
            #expect(!service.isRoomNewlyCreated(jidString: key, accountID: testAccountID))
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

            #expect(service.participants(forRoomJIDString: key, accountID: testAccountID).isEmpty)
            #expect(service.roomFlags(forRoomJIDString: key, accountID: testAccountID).isEmpty)
            #expect(!service.isRoomNewlyCreated(jidString: key, accountID: testAccountID))
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

            #expect(service.participants(forRoomJIDString: key, accountID: testAccountID).isEmpty)
            #expect(service.roomFlags(forRoomJIDString: key, accountID: testAccountID).isEmpty)
            #expect(!service.isRoomNewlyCreated(jidString: key, accountID: testAccountID))
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
            #expect(service.participants(forRoomJIDString: roomA.description, accountID: accountA).isEmpty)
            #expect(service.roomFlags(forRoomJIDString: roomA.description, accountID: accountA).isEmpty)
            #expect(!service.isRoomNewlyCreated(jidString: roomA.description, accountID: accountA))

            // B's room state is preserved.
            #expect(!service.participants(forRoomJIDString: roomB.description, accountID: accountB).isEmpty)
            #expect(!service.roomFlags(forRoomJIDString: roomB.description, accountID: accountB).isEmpty)
            #expect(service.isRoomNewlyCreated(jidString: roomB.description, accountID: accountB))
        }

        /// Pending room invites are one-shot messages the server never re-delivers, so they must outlive a
        /// transient blip (`connectionLost`/`streamError`/`redirect`) but drop on a user-initiated teardown.
        /// `purgeAccount` is the real disconnect/delete path; the `.disconnected(.requested)` branch is the
        /// defensive symmetry with `PresenceService`. Both clears are scoped to the one account, never global.
        @Test
        @MainActor
        func `invites survive a blip but clear on user-initiated teardown`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let accountA = UUID()
            let accountB = UUID()
            let room = try #require(BareJID.parse("room@conference.example.com"))
            let inviter = try #require(BareJID.parse("inviter@example.com"))
            let invite = RoomInvite(room: room, from: .bare(inviter))

            await service.handleEvent(.roomInviteReceived(invite), accountID: accountA)
            await service.handleEvent(.roomInviteReceived(invite), accountID: accountB)
            #expect(service.pendingInvites.contains { $0.accountID == accountA })
            #expect(service.pendingInvites.contains { $0.accountID == accountB })

            // Seed live room state on A so the blip below proves the divergence: a blip clears the blip-safe
            // live state (rooms/locks/typing) while preserving invites — not the other way around.
            let occupancy = RoomOccupancy(
                nickname: "me",
                occupants: [RoomOccupant(nickname: "me", affiliation: .owner, role: .moderator)],
                subject: nil,
                flags: [.logged]
            )
            await service.handleEvent(.roomJoined(room: room, occupancy: occupancy, isNewlyCreated: true), accountID: accountA)
            #expect(!service.roomFlags(forRoomJIDString: room.description, accountID: accountA).isEmpty)

            // A blip preserves invites but still clears live room state: dropped connection, stream error, and
            // redirect all leave invites intact.
            await service.handleEvent(.disconnected(.connectionLost("network down")), accountID: accountA)
            #expect(service.pendingInvites.contains { $0.accountID == accountA })
            #expect(service.roomFlags(forRoomJIDString: room.description, accountID: accountA).isEmpty)
            await service.handleEvent(.disconnected(.streamError(nil, text: nil)), accountID: accountA)
            #expect(service.pendingInvites.contains { $0.accountID == accountA })
            await service.handleEvent(.disconnected(.redirect(host: "example.com", port: 5222)), accountID: accountA)
            #expect(service.pendingInvites.contains { $0.accountID == accountA })

            // User-initiated teardown drops only A's invites; B's still-connected invite stays (no global clear).
            service.purgeAccount(accountA)
            #expect(!service.pendingInvites.contains { $0.accountID == accountA })
            #expect(service.pendingInvites.contains { $0.accountID == accountB })

            // Defensive symmetry: the `.requested` branch clears invites if the event ever reaches the handler.
            await service.handleEvent(.roomInviteReceived(invite), accountID: accountA)
            #expect(service.pendingInvites.contains { $0.accountID == accountA })
            await service.handleEvent(.disconnected(.requested), accountID: accountA)
            #expect(!service.pendingInvites.contains { $0.accountID == accountA })
            #expect(service.pendingInvites.contains { $0.accountID == accountB })
        }
    }
}
