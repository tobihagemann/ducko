import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCore

extension DuckoIntegrationTests.ProtocolLayer {
    struct PresenceTests {
        // MARK: - Shared Helper

        /// Sets up Alice and Bob with a one-directional presence subscription:
        /// Bob subscribes to Alice, Alice approves, so Alice's broadcasts reach Bob.
        ///
        /// Per RFC 6121 §4.5.2, Alice's server routes her presence to contacts with
        /// `subscription='from'` or `'both'`. Bob sending the subscribe request puts
        /// `subscription='from'` on Alice's side after approval.
        @MainActor
        private static func setUpBobSubscribedToAlice(_ harness: TestHarness) async throws {
            try await harness.setUp(accounts: [
                "alice": TestCredentials.alice,
                "bob": TestCredentials.bob
            ])

            let alice = try #require(harness.accounts["alice"])
            let bob = try #require(harness.accounts["bob"])
            let aliceBareJID = try #require(BareJID.parse(TestCredentials.alice.jid))
            let bobBareJID = try #require(BareJID.parse(TestCredentials.bob.jid))

            let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
            let bobClient = try #require(harness.environment.accountService.client(for: bob.accountID))
            let aliceRoster = try #require(await aliceClient.module(ofType: RosterModule.self))
            let bobRoster = try #require(await bobClient.module(ofType: RosterModule.self))

            // Register cleanup before any roster mutation.
            harness.addCleanup { try? await bobRoster.removeContact(jid: aliceBareJID) }
            harness.addCleanup { try? await aliceRoster.removeContact(jid: bobBareJID) }

            // Bob requests to see Alice's presence.
            try await bobRoster.subscribe(to: aliceBareJID)

            // Alice sees the request.
            _ = try await alice.waitForEvent { event in
                if case let .presenceSubscriptionRequest(from) = event, from == bobBareJID {
                    return true
                }
                return false
            }

            // Alice approves — creates subscription='from' for Bob on Alice's side.
            try await aliceRoster.approveSubscription(from: bobBareJID)

            // Bob sees the approval — confirms the round-trip so subsequent assertions
            // don't race the push.
            _ = try await bob.waitForEvent { event in
                if case let .presenceSubscriptionApproved(from) = event, from == aliceBareJID {
                    return true
                }
                return false
            }
        }

        // MARK: - Tests

        @Test @MainActor func `Broadcasting available presence is observed by a subscribed peer`() async throws {
            try await TestHarness.withHarness { harness in
                try await Self.setUpBobSubscribedToAlice(harness)

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))

                let alicePresence = try #require(await aliceClient.module(ofType: PresenceModule.self))
                let status = "available-\(UUID().uuidString.prefix(8))"
                try await alicePresence.broadcastPresence(show: nil, status: status)

                _ = try await bob.waitForEvent { event in
                    if case let .presenceUpdated(from: _, presence) = event,
                       presence.status == status,
                       presence.presenceType == nil {
                        return true
                    }
                    return false
                }
            }
        }

        @Test @MainActor func `Status message round-trips`() async throws {
            try await TestHarness.withHarness { harness in
                try await Self.setUpBobSubscribedToAlice(harness)

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))

                let alicePresence = try #require(await aliceClient.module(ofType: PresenceModule.self))
                let status = "my-status-\(UUID().uuidString.prefix(8))"
                try await alicePresence.broadcastPresence(show: nil, status: status)

                _ = try await bob.waitForEvent { event in
                    if case let .presenceUpdated(from: _, presence) = event,
                       presence.status == status {
                        return true
                    }
                    return false
                }
            }
        }

        @Test(arguments: [XMPPPresence.Show.chat, .away, .xa, .dnd])
        @MainActor func `Show states are propagated`(show: XMPPPresence.Show) async throws {
            try await TestHarness.withHarness { harness in
                try await Self.setUpBobSubscribedToAlice(harness)

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))

                let alicePresence = try #require(await aliceClient.module(ofType: PresenceModule.self))
                try await alicePresence.broadcastPresence(show: show)

                _ = try await bob.waitForEvent { event in
                    if case let .presenceUpdated(from: _, presence) = event,
                       presence.show == show {
                        return true
                    }
                    return false
                }
            }
        }

        @Test @MainActor func `Service setPresence updates myPresence and broadcasts`() async throws {
            try await TestHarness.withHarness { harness in
                try await Self.setUpBobSubscribedToAlice(harness)

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])

                await harness.environment.presenceService.setPresence(
                    .away,
                    message: "afk",
                    accountID: alice.accountID
                )

                // Bob observes the broadcast.
                _ = try await bob.waitForEvent { event in
                    if case let .presenceUpdated(from: _, presence) = event,
                       presence.show == .away {
                        return true
                    }
                    return false
                }

                // Verify service-level state.
                try await alice.waitForCondition({ @MainActor in
                    harness.environment.presenceService.myPresence == .away
                        && harness.environment.presenceService.myStatusMessage == "afk"
                }, timeout: TestTimeout.event)
            }
        }

        @Test @MainActor func `Service applyPresence offline disconnects the account`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let alice = try #require(harness.accounts["alice"])

                await harness.environment.presenceService.applyPresence(
                    .offline,
                    message: nil,
                    accountID: alice.accountID,
                    connect: { _ in },
                    disconnect: { id in
                        await harness.environment.accountService.disconnect(accountID: id)
                    }
                )

                try await alice.waitForCondition({ @MainActor in
                    harness.environment.presenceService.myPresence == .offline
                }, timeout: TestTimeout.event)

                try await alice.waitForCondition({ @MainActor in
                    if case .disconnected = harness.environment.accountService.connectionStates[alice.accountID] {
                        return true
                    }
                    return false
                }, timeout: TestTimeout.event)
            }
        }
    }
}
