import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCore

extension DuckoIntegrationTests.ProtocolLayer {
    struct MessagingTests {
        // MARK: - Protocol Layer

        @Test @MainActor func `Alice sends a direct message to Bob via raw module`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let bob = try #require(harness.accounts["bob"])
                let alice = try #require(harness.accounts["alice"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))

                let chat = try #require(await aliceClient.module(ofType: ChatModule.self))
                let body = "msg-\(UUID().uuidString.prefix(8))"
                try await chat.sendMessage(to: .bare(bobJID), body: body)

                _ = try await bob.waitForEvent { event in
                    if case let .messageReceived(m) = event, m.body == body {
                        return true
                    }
                    return false
                }
            }
        }

        @Test @MainActor func `Outgoing message id round-trips to receiver`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let bob = try #require(harness.accounts["bob"])
                let alice = try #require(harness.accounts["alice"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))

                let chat = try #require(await aliceClient.module(ofType: ChatModule.self))
                let body = "msg-\(UUID().uuidString.prefix(8))"
                let id = aliceClient.generateID()
                try await chat.sendMessage(to: .bare(bobJID), body: body, id: id)

                _ = try await bob.waitForEvent { event in
                    if case let .messageReceived(m) = event, m.id == id {
                        return true
                    }
                    return false
                }
            }
        }

        @Test @MainActor func `Delivery receipt is auto-echoed for markable messages`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))

                let chat = try #require(await aliceClient.module(ofType: ChatModule.self))
                let body = "msg-\(UUID().uuidString.prefix(8))"
                let stanzaID = aliceClient.generateID()
                try await chat.sendMessage(
                    to: .bare(bobJID),
                    body: body,
                    id: stanzaID,
                    requestReceipt: true,
                    markable: true
                )

                // Bob's ReceiptsModule auto-echoes the receipt. Alice waits immediately
                // after sendMessage — do not interpose a Bob-side waitForEvent.
                _ = try await alice.waitForEvent { event in
                    if case let .deliveryReceiptReceived(messageID, from: _) = event,
                       messageID == stanzaID {
                        return true
                    }
                    return false
                }
            }
        }

        @Test @MainActor func `Chat marker displayed is delivered`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
                let bobClient = try #require(harness.environment.accountService.client(for: bob.accountID))
                let aliceJID = try #require(BareJID.parse(TestCredentials.alice.jid))
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))

                let aliceChat = try #require(await aliceClient.module(ofType: ChatModule.self))
                let body = "msg-\(UUID().uuidString.prefix(8))"
                let stanzaID = aliceClient.generateID()
                try await aliceChat.sendMessage(to: .bare(bobJID), body: body, id: stanzaID, markable: true)

                // Bob receives the message.
                _ = try await bob.waitForEvent { event in
                    if case let .messageReceived(m) = event, m.body == body {
                        return true
                    }
                    return false
                }

                // Bob sends a displayed marker.
                let bobReceipts = try #require(await bobClient.module(ofType: ReceiptsModule.self))
                try await bobReceipts.sendDisplayedMarker(to: .bare(aliceJID), messageID: stanzaID)

                // Alice sees the chat marker.
                _ = try await alice.waitForEvent { event in
                    if case let .chatMarkerReceived(messageID, type, from: _) = event,
                       messageID == stanzaID, type == .displayed {
                        return true
                    }
                    return false
                }
            }
        }

        @Test(arguments: ChatState.allCases) @MainActor func `Chat state reaches the peer`(chatState: ChatState) async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
                let bob = try #require(harness.accounts["bob"])
                let aliceBareJID = try #require(BareJID.parse(TestCredentials.alice.jid))
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))

                let states = try #require(await aliceClient.module(ofType: ChatStatesModule.self))
                try await states.sendChatState(chatState, to: .bare(bobJID))

                _ = try await bob.waitForEvent { event in
                    if case let .chatStateChanged(from, state) = event,
                       from == aliceBareJID, state == chatState {
                        return true
                    }
                    return false
                }
            }
        }

        @Test @MainActor func `Message correction replaces the original`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let bob = try #require(harness.accounts["bob"])
                let alice = try #require(harness.accounts["alice"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))

                let chat = try #require(await aliceClient.module(ofType: ChatModule.self))
                let originalBody = "msg-\(UUID().uuidString.prefix(8))"
                let originalID = aliceClient.generateID()
                try await chat.sendMessage(to: .bare(bobJID), body: originalBody, id: originalID)

                // Bob receives the original.
                _ = try await bob.waitForEvent { event in
                    if case let .messageReceived(m) = event, m.body == originalBody {
                        return true
                    }
                    return false
                }

                // Alice sends a correction.
                let newBody = "msg-\(UUID().uuidString.prefix(8))"
                try await chat.sendCorrection(to: .bare(bobJID), body: newBody, replacingID: originalID)

                // Bob sees the correction.
                _ = try await bob.waitForEvent { event in
                    if case let .messageCorrected(origID, correctedBody, from: _) = event,
                       origID == originalID, correctedBody == newBody {
                        return true
                    }
                    return false
                }
            }
        }

        @Test @MainActor func `Message retraction propagates`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let bob = try #require(harness.accounts["bob"])
                let alice = try #require(harness.accounts["alice"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))

                let chat = try #require(await aliceClient.module(ofType: ChatModule.self))
                let body = "msg-\(UUID().uuidString.prefix(8))"
                let stanzaID = aliceClient.generateID()
                try await chat.sendMessage(to: .bare(bobJID), body: body, id: stanzaID)

                // Bob receives the message.
                _ = try await bob.waitForEvent { event in
                    if case let .messageReceived(m) = event, m.body == body {
                        return true
                    }
                    return false
                }

                // Alice retracts it.
                try await chat.sendRetraction(to: .bare(bobJID), originalID: stanzaID)

                // Bob sees the retraction.
                _ = try await bob.waitForEvent { event in
                    if case let .messageRetracted(origID, from: _) = event, origID == stanzaID {
                        return true
                    }
                    return false
                }
            }
        }

        // MARK: - Service Layer

        @Test @MainActor func `Service sendMessage delivers to peer`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))

                let body = "msg-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendMessage(
                    to: bobJID,
                    body: body,
                    accountID: alice.accountID
                )

                _ = try await bob.waitForEvent { event in
                    if case let .messageReceived(m) = event, m.body == body {
                        return true
                    }
                    return false
                }
            }
        }

        @Test @MainActor func `Service sendCorrection round-trips via transcript store`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))

                let initialBody = "msg-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendMessage(
                    to: bobJID,
                    body: initialBody,
                    accountID: alice.accountID
                )

                // Bob receives the original and captures its id.
                let received = try await bob.waitForEvent { event in
                    if case let .messageReceived(m) = event, m.body == initialBody {
                        return true
                    }
                    return false
                }
                guard case let .messageReceived(receivedMessage) = received else {
                    throw TestHarnessError.streamClosed
                }
                let capturedID = try #require(receivedMessage.id)

                // Alice sends a correction via service (looks up transcript store).
                let updatedBody = "msg-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendCorrection(
                    to: bobJID,
                    originalStanzaID: capturedID,
                    newBody: updatedBody,
                    accountID: alice.accountID
                )

                // Bob sees the correction.
                _ = try await bob.waitForEvent { event in
                    if case let .messageCorrected(origID, newBody, from: _) = event,
                       origID == capturedID, newBody == updatedBody {
                        return true
                    }
                    return false
                }

                // Verify Alice's transcript persists the edit.
                let aliceConversation = try await harness.environment.chatService.openConversation(for: bobJID, accountID: alice.accountID)
                let messages = await harness.environment.chatService.loadMessages(for: aliceConversation.id)
                try #require(!messages.isEmpty)
                let edited = try #require(messages.first { $0.stanzaID == capturedID })
                #expect(edited.isEdited)
                #expect(edited.body == updatedBody)
            }
        }

        @Test @MainActor func `Service retractMessage propagates to peer`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))

                let body = "msg-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendMessage(
                    to: bobJID,
                    body: body,
                    accountID: alice.accountID
                )

                // Bob receives and captures the id.
                let received = try await bob.waitForEvent { event in
                    if case let .messageReceived(m) = event, m.body == body {
                        return true
                    }
                    return false
                }
                guard case let .messageReceived(receivedMessage) = received else {
                    throw TestHarnessError.streamClosed
                }
                let capturedID = try #require(receivedMessage.id)

                // Alice retracts via service.
                try await harness.environment.chatService.retractMessage(
                    stanzaID: capturedID,
                    to: bobJID,
                    accountID: alice.accountID
                )

                // Bob sees the retraction.
                _ = try await bob.waitForEvent { event in
                    if case let .messageRetracted(origID, from: _) = event, origID == capturedID {
                        return true
                    }
                    return false
                }

                // Verify Alice's transcript persists the retraction.
                let aliceConversation = try await harness.environment.chatService.openConversation(for: bobJID, accountID: alice.accountID)
                let messages = await harness.environment.chatService.loadMessages(for: aliceConversation.id)
                try #require(!messages.isEmpty)
                let retracted = try #require(messages.first { $0.stanzaID == capturedID })
                #expect(retracted.isRetracted)
            }
        }

        @Test @MainActor func `Service sendReply carries the reply marker`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))

                let initialBody = "msg-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendMessage(
                    to: bobJID,
                    body: initialBody,
                    accountID: alice.accountID
                )

                // Bob receives and captures the id.
                let received = try await bob.waitForEvent { event in
                    if case let .messageReceived(m) = event, m.body == initialBody {
                        return true
                    }
                    return false
                }
                guard case let .messageReceived(receivedMessage) = received else {
                    throw TestHarnessError.streamClosed
                }
                let originalID = try #require(receivedMessage.id)

                // Alice sends a reply via service.
                let replyBody = "msg-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendReply(
                    to: bobJID,
                    body: replyBody,
                    replyToStanzaID: originalID,
                    accountID: alice.accountID
                )

                // Bob receives the reply with the <reply/> marker.
                let replyEvent = try await bob.waitForEvent { event in
                    if case let .messageReceived(m) = event, m.body == replyBody {
                        return true
                    }
                    return false
                }
                guard case let .messageReceived(replyMessage) = replyEvent else {
                    throw TestHarnessError.streamClosed
                }
                #expect(replyMessage.element.child(named: "reply", namespace: XMPPNamespaces.messageReply) != nil)
            }
        }

        @Test @MainActor func `Service sendDisplayedMarker notifies peer`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let aliceJID = try #require(BareJID.parse(TestCredentials.alice.jid))
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))

                // Alice sends a message via service.
                let body = "msg-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendMessage(
                    to: bobJID,
                    body: body,
                    accountID: alice.accountID
                )

                // Bob receives and captures the id.
                let received = try await bob.waitForEvent { event in
                    if case let .messageReceived(m) = event, m.body == body {
                        return true
                    }
                    return false
                }
                guard case let .messageReceived(receivedMessage) = received else {
                    throw TestHarnessError.streamClosed
                }
                let stanzaID = try #require(receivedMessage.id)

                // Bob sends a displayed marker via service.
                try await harness.environment.chatService.sendDisplayedMarker(
                    to: aliceJID,
                    messageStanzaID: stanzaID,
                    accountID: bob.accountID
                )

                // Alice sees the chat marker.
                _ = try await alice.waitForEvent { event in
                    if case let .chatMarkerReceived(messageID, type, from: _) = event,
                       messageID == stanzaID, type == .displayed {
                        return true
                    }
                    return false
                }
            }
        }
    }
}
