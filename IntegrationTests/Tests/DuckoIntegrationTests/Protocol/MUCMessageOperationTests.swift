import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.ProtocolLayer {
    struct MUCMessageOperationTests {
        /// Extracts the room-assigned stanza-id from a message element.
        private static func roomStanzaID(from element: DuckoXMPP.XMLElement, roomJID: BareJID) -> String? {
            element.children(named: "stanza-id")
                .first(where: { $0.namespace == XMPPNamespaces.stanzaID && $0.attribute("by") == roomJID.description })
                .flatMap { $0.attribute("id") }
        }

        // MARK: - Protocol Layer

        @Test @MainActor func `MUC message correction replaces original`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")

                let bob = try #require(harness.accounts["bob"])
                let bobClient = try #require(harness.environment.accountService.client(for: bob.accountID))
                let bobMUC = try #require(await bobClient.module(ofType: MUCModule.self))

                try await bobMUC.joinRoom(roomJID, nickname: "bob")
                harness.addCleanup { try? await bobMUC.leaveRoom(roomJID) }

                _ = try await bob.waitForEvent { event in
                    if case let .roomJoined(room, _, _) = event, room == roomJID { return true }
                    return false
                }

                let alice = try #require(harness.accounts["alice"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
                let aliceMUC = try #require(await aliceClient.module(ofType: MUCModule.self))

                let originalBody = "msg-\(UUID().uuidString.prefix(8))"
                let originalID = aliceClient.generateID()
                try await aliceMUC.sendMessage(to: roomJID, body: originalBody, id: originalID)

                _ = try await bob.waitForEvent { event in
                    if case let .roomMessageReceived(m) = event, m.body == originalBody { return true }
                    return false
                }

                let newBody = "msg-\(UUID().uuidString.prefix(8))"
                try await aliceMUC.sendCorrection(to: roomJID, body: newBody, replacingID: originalID)

                _ = try await bob.waitForEvent { event in
                    if case let .messageCorrected(origID, correctedBody, from: _) = event,
                       origID == originalID, correctedBody == newBody {
                        return true
                    }
                    return false
                }
            }
        }

        @Test @MainActor func `Moderator retracts a message`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let bobClient = try #require(harness.environment.accountService.client(for: bob.accountID))
                let bobMUC = try #require(await bobClient.module(ofType: MUCModule.self))

                try await bobMUC.joinRoom(roomJID, nickname: "bob")
                harness.addCleanup { try? await bobMUC.leaveRoom(roomJID) }

                _ = try await bob.waitForEvent { event in
                    if case let .roomJoined(room, _, _) = event, room == roomJID { return true }
                    return false
                }

                // Bob sends a message.
                let body = "msg-\(UUID().uuidString.prefix(8))"
                try await bobMUC.sendMessage(to: roomJID, body: body)

                // Alice captures the room-assigned stanza-id.
                let receivedEvent = try await alice.waitForEvent { event in
                    if case let .roomMessageReceived(m) = event, m.body == body { return true }
                    return false
                }
                guard case let .roomMessageReceived(receivedMessage) = receivedEvent else {
                    throw TestHarnessError.streamClosed
                }

                // Extract stanza-id assigned by the room (filter by `by` == room JID).
                let stanzaID = try #require(Self.roomStanzaID(from: receivedMessage.element, roomJID: roomJID))

                // Alice (moderator/owner) retracts bob's message.
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
                let aliceMUC = try #require(await aliceClient.module(ofType: MUCModule.self))
                try await aliceMUC.moderateMessage(room: roomJID, stanzaID: stanzaID, reason: "inappropriate")

                let moderationEvent = try await bob.waitForEvent { event in
                    if case let .messageModerated(origID, _, room, _) = event,
                       origID == stanzaID, room == roomJID {
                        return true
                    }
                    return false
                }
                guard case let .messageModerated(_, _, _, reason) = moderationEvent else {
                    throw TestHarnessError.streamClosed
                }
                #expect(reason == "inappropriate")
            }
        }

        // MARK: - Service Layer

        @Test @MainActor func `Service moderates a message`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let bobClient = try #require(harness.environment.accountService.client(for: bob.accountID))
                let bobMUC = try #require(await bobClient.module(ofType: MUCModule.self))

                try await bobMUC.joinRoom(roomJID, nickname: "bob")
                harness.addCleanup { try? await bobMUC.leaveRoom(roomJID) }

                _ = try await bob.waitForEvent { event in
                    if case let .roomJoined(room, _, _) = event, room == roomJID { return true }
                    return false
                }

                // Bob sends a message.
                let body = "msg-\(UUID().uuidString.prefix(8))"
                try await bobMUC.sendMessage(to: roomJID, body: body)

                // Alice captures the room-assigned stanza-id.
                let receivedEvent = try await alice.waitForEvent { event in
                    if case let .roomMessageReceived(m) = event, m.body == body { return true }
                    return false
                }
                guard case let .roomMessageReceived(receivedMessage) = receivedEvent else {
                    throw TestHarnessError.streamClosed
                }

                let stanzaID = try #require(Self.roomStanzaID(from: receivedMessage.element, roomJID: roomJID))

                // Alice moderates via service.
                try await harness.environment.chatService.moderateMessage(
                    serverID: stanzaID,
                    inRoomJIDString: roomJID.description,
                    reason: "inappropriate",
                    accountID: alice.accountID
                )

                let moderationEvent = try await bob.waitForEvent { event in
                    if case let .messageModerated(origID, _, room, _) = event,
                       origID == stanzaID, room == roomJID {
                        return true
                    }
                    return false
                }
                guard case let .messageModerated(_, _, _, reason) = moderationEvent else {
                    throw TestHarnessError.streamClosed
                }
                #expect(reason == "inappropriate")
            }
        }
    }
}
