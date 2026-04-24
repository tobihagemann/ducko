import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.ProtocolLayer {
    struct RosterTests {
        @Test @MainActor func `Roster loads on connect`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let alice = try #require(harness.accounts["alice"])

                // setUp already asserted .rosterLoaded arrived. Additionally verify the
                // service processed the load by calling loadContacts, which populates
                // groupsByAccount for the account — this should not throw.
                try await harness.environment.rosterService.loadContacts(for: alice.accountID)
            }
        }

        @Test @MainActor func `Add and remove roster item via module`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let alice = try #require(harness.accounts["alice"])
                let roster = try await harness.module(RosterModule.self, for: "alice")

                let bobBareJID = try harness.jid(for: TestCredentials.bob)
                let tempJID = try #require(BareJID.parse("inttest-\(UUID().uuidString.prefix(8))@\(bobBareJID.domainPart)"))

                // Register cleanup before any roster mutation.
                harness.addCleanup { try? await roster.removeContact(jid: tempJID) }

                // Add contact and wait for roster push.
                try await roster.addContact(jid: tempJID, name: "Test")
                _ = try await alice.waitForEvent { event in
                    if case let .rosterItemChanged(item) = event,
                       item.jid == tempJID, item.subscription != .remove {
                        return true
                    }
                    return false
                }

                // Remove contact and wait for removal push.
                try await roster.removeContact(jid: tempJID)
                _ = try await alice.waitForEvent { event in
                    if case let .rosterItemChanged(item) = event,
                       item.jid == tempJID, item.subscription == .remove {
                        return true
                    }
                    return false
                }
            }
        }

        @Test(.enabled(if: TestCredentials.isDaveAvailable, "Dave credentials not set"))
        @MainActor func `Presence subscription is approved`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "dave": TestCredentials.dave
                ])

                let alice = try #require(harness.accounts["alice"])
                let dave = try #require(harness.accounts["dave"])
                let aliceBareJID = try harness.jid(for: TestCredentials.alice)
                let daveBareJID = try harness.jid(for: TestCredentials.dave)

                let aliceRoster = try await harness.module(RosterModule.self, for: "alice")
                let daveRoster = try await harness.module(RosterModule.self, for: "dave")

                try await Self.assertNoBaselineSubscription(
                    harness: harness, alice: alice, dave: dave,
                    aliceJID: aliceBareJID, daveJID: daveBareJID
                )

                // Register cleanup before any roster mutation.
                harness.addCleanup { try? await daveRoster.removeContact(jid: aliceBareJID) }
                harness.addCleanup { try? await aliceRoster.removeContact(jid: daveBareJID) }

                // Alice subscribes to Dave.
                try await aliceRoster.subscribe(to: daveBareJID)

                // Dave sees the subscription request.
                _ = try await dave.waitForEvent { event in
                    if case let .presenceSubscriptionRequest(from) = event, from == aliceBareJID {
                        return true
                    }
                    return false
                }

                // Dave approves.
                try await daveRoster.approveSubscription(from: aliceBareJID)

                // Alice sees the approval.
                _ = try await alice.waitForEvent { event in
                    if case let .presenceSubscriptionApproved(from) = event, from == daveBareJID {
                        return true
                    }
                    return false
                }
            }
        }

        @Test(.enabled(if: TestCredentials.isDaveAvailable, "Dave credentials not set"))
        @MainActor func `Presence subscription is denied`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "dave": TestCredentials.dave
                ])

                let alice = try #require(harness.accounts["alice"])
                let dave = try #require(harness.accounts["dave"])
                let aliceBareJID = try harness.jid(for: TestCredentials.alice)
                let daveBareJID = try harness.jid(for: TestCredentials.dave)

                let aliceRoster = try await harness.module(RosterModule.self, for: "alice")
                let daveRoster = try await harness.module(RosterModule.self, for: "dave")

                try await Self.assertNoBaselineSubscription(
                    harness: harness, alice: alice, dave: dave,
                    aliceJID: aliceBareJID, daveJID: daveBareJID
                )

                // Register cleanup before any roster mutation.
                harness.addCleanup { try? await daveRoster.removeContact(jid: aliceBareJID) }
                harness.addCleanup { try? await aliceRoster.removeContact(jid: daveBareJID) }

                // Alice subscribes to Dave.
                try await aliceRoster.subscribe(to: daveBareJID)

                // Dave sees the subscription request.
                _ = try await dave.waitForEvent { event in
                    if case let .presenceSubscriptionRequest(from) = event, from == aliceBareJID {
                        return true
                    }
                    return false
                }

                // Dave denies.
                try await daveRoster.denySubscription(from: aliceBareJID)

                // Alice sees the revocation.
                _ = try await alice.waitForEvent { event in
                    if case let .presenceSubscriptionRevoked(from) = event, from == daveBareJID {
                        return true
                    }
                    return false
                }
            }
        }

        @Test @MainActor func `loadContacts populates roster service groups`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let alice = try #require(harness.accounts["alice"])

                // loadContacts should return without throwing; an empty roster is valid.
                try await harness.environment.rosterService.loadContacts(for: alice.accountID)
            }
        }

        @Test @MainActor func `Service addContact and removeContact round-trip`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let alice = try #require(harness.accounts["alice"])
                let bobBareJID = try harness.jid(for: TestCredentials.bob)
                let tempJID = try #require(BareJID.parse("inttest-\(UUID().uuidString.prefix(8))@\(bobBareJID.domainPart)"))

                // Register cleanup before roster mutation.
                harness.addCleanup {
                    try? await harness.environment.rosterService.removeContact(
                        jidString: tempJID.description,
                        accountID: alice.accountID
                    )
                }

                // Add contact via service (also fires subscribe).
                try await harness.environment.rosterService.addContact(
                    jid: tempJID,
                    name: nil,
                    groups: [],
                    accountID: alice.accountID
                )

                // Poll until the contact appears in service state.
                try await alice.waitForCondition({ @MainActor in
                    harness.environment.rosterService.groups
                        .flatMap(\.contacts)
                        .contains { $0.jid == tempJID && $0.accountID == alice.accountID }
                }, timeout: TestTimeout.event)

                // Remove contact via service.
                try await harness.environment.rosterService.removeContact(
                    jidString: tempJID.description,
                    accountID: alice.accountID
                )

                // Poll until the contact disappears from service state.
                try await alice.waitForCondition({ @MainActor in
                    !harness.environment.rosterService.groups
                        .flatMap(\.contacts)
                        .contains { $0.jid == tempJID && $0.accountID == alice.accountID }
                }, timeout: TestTimeout.event)
            }
        }

        /// Precondition guard for the Dave-based subscription tests. Fails
        /// loudly if Dave's roster carries any lingering alice entry (stale
        /// state from an interrupted prior run, or baseline misconfiguration)
        /// so the test's subscription-mutation logic starts from a clean slate
        /// and cleanup doesn't remove real baseline state.
        @MainActor
        private static func assertNoBaselineSubscription(
            harness: TestHarness, alice: ConnectedAccount, dave: ConnectedAccount,
            aliceJID: BareJID, daveJID: BareJID
        ) async throws {
            try await harness.environment.rosterService.loadContacts(for: alice.accountID)
            try await harness.environment.rosterService.loadContacts(for: dave.accountID)
            let contacts = harness.environment.rosterService.groups.flatMap(\.contacts)
            let aliceHasDave = contacts.contains { $0.accountID == alice.accountID && $0.jid == daveJID }
            let daveHasAlice = contacts.contains { $0.accountID == dave.accountID && $0.jid == aliceJID }
            try #require(!aliceHasDave, "Alice must not have Dave in roster before subscription test; provision dave with an empty roster or clean up prior state")
            try #require(!daveHasAlice, "Dave must not have Alice in roster before subscription test; provision dave with an empty roster or clean up prior state")
        }

        @Test(.enabled(if: TestCredentials.isDaveAvailable, "Dave credentials not set"))
        @MainActor func `Service approveSubscription clears pending request`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "dave": TestCredentials.dave
                ])

                let alice = try #require(harness.accounts["alice"])
                let dave = try #require(harness.accounts["dave"])
                let aliceBareJID = try harness.jid(for: TestCredentials.alice)
                let daveBareJID = try harness.jid(for: TestCredentials.dave)

                let aliceRoster = try await harness.module(RosterModule.self, for: "alice")
                let daveRoster = try await harness.module(RosterModule.self, for: "dave")

                try await Self.assertNoBaselineSubscription(
                    harness: harness, alice: alice, dave: dave,
                    aliceJID: aliceBareJID, daveJID: daveBareJID
                )

                // Register cleanup before any roster mutation.
                harness.addCleanup { try? await daveRoster.removeContact(jid: aliceBareJID) }
                harness.addCleanup { try? await aliceRoster.removeContact(jid: daveBareJID) }

                // Alice adds Dave via service (which also subscribes).
                try await harness.environment.rosterService.addContact(
                    jid: daveBareJID,
                    name: nil,
                    groups: [],
                    accountID: alice.accountID
                )

                // Dave waits for the subscription request.
                _ = try await dave.waitForEvent { event in
                    if case let .presenceSubscriptionRequest(from) = event, from == aliceBareJID {
                        return true
                    }
                    return false
                }

                // Dave approves via service.
                try await harness.environment.rosterService.approveSubscription(
                    jidString: aliceBareJID.description,
                    accountID: dave.accountID
                )

                // Verify pending request is cleared on Dave's side.
                try await dave.waitForCondition({ @MainActor in
                    !harness.environment.presenceService.pendingSubscriptionRequests.contains(aliceBareJID)
                }, timeout: TestTimeout.event)
            }
        }

        @Test(.enabled(if: TestCredentials.isDaveAvailable, "Dave credentials not set"))
        @MainActor func `Service denySubscription clears pending request`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "dave": TestCredentials.dave
                ])

                let alice = try #require(harness.accounts["alice"])
                let dave = try #require(harness.accounts["dave"])
                let aliceBareJID = try harness.jid(for: TestCredentials.alice)
                let daveBareJID = try harness.jid(for: TestCredentials.dave)

                let aliceRoster = try await harness.module(RosterModule.self, for: "alice")
                let daveRoster = try await harness.module(RosterModule.self, for: "dave")

                try await Self.assertNoBaselineSubscription(
                    harness: harness, alice: alice, dave: dave,
                    aliceJID: aliceBareJID, daveJID: daveBareJID
                )

                // Register cleanup before any roster mutation.
                harness.addCleanup { try? await daveRoster.removeContact(jid: aliceBareJID) }
                harness.addCleanup { try? await aliceRoster.removeContact(jid: daveBareJID) }

                // Alice adds Dave via service (which also subscribes).
                try await harness.environment.rosterService.addContact(
                    jid: daveBareJID,
                    name: nil,
                    groups: [],
                    accountID: alice.accountID
                )

                // Dave waits for the subscription request.
                _ = try await dave.waitForEvent { event in
                    if case let .presenceSubscriptionRequest(from) = event, from == aliceBareJID {
                        return true
                    }
                    return false
                }

                // Wait for service state to register the pending request.
                try await dave.waitForCondition({ @MainActor in
                    harness.environment.presenceService.pendingSubscriptionRequests.contains(aliceBareJID)
                }, timeout: TestTimeout.event)

                // Dave denies via service.
                try await harness.environment.rosterService.denySubscription(
                    jidString: aliceBareJID.description,
                    accountID: dave.accountID
                )

                // Verify pending request is cleared on Dave's side.
                try await dave.waitForCondition({ @MainActor in
                    !harness.environment.presenceService.pendingSubscriptionRequests.contains(aliceBareJID)
                }, timeout: TestTimeout.event)

                // Alice sees the revocation.
                _ = try await alice.waitForEvent { event in
                    if case let .presenceSubscriptionRevoked(from) = event, from == daveBareJID {
                        return true
                    }
                    return false
                }
            }
        }
    }
}
