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

                let snapshot = try await harness.environment.rosterService.synchronizeRoster(accountID: alice.accountID)
                #expect(snapshot.allSatisfy { $0.accountID == alice.accountID })
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
                    if case let .rosterUpdated(update) = event, case let .delta(item) = update.contents,
                       item.jid == tempJID, item.subscription != .remove {
                        return true
                    }
                    return false
                }

                // Remove contact and wait for removal push.
                try await roster.removeContact(jid: tempJID)
                _ = try await alice.waitForEvent { event in
                    if case let .rosterUpdated(update) = event, case let .delta(item) = update.contents,
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

                try await SubscriptionDance.assertNoSubscription(
                    harness: harness,
                    first: TestCredentials.alice,
                    second: TestCredentials.dave
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

        @Test(
            .enabled(if: TestCredentials.isDaveAvailable, "Dave credentials not set"),
            arguments: ["bob", "carol"]
        )
        @MainActor func `Peer has no baseline subscription with Dave`(
            peerLabel: String
        ) async throws {
            // Swift Testing renders the parameter value in test names and
            // reports; pass the label rather than the credential so the
            // password field doesn't leak into reflection-based displays.
            let peer = peerLabel == "bob" ? TestCredentials.bob : TestCredentials.carol

            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    peer.label: peer,
                    "dave": TestCredentials.dave
                ])

                try await SubscriptionDance.assertNoSubscription(
                    harness: harness,
                    first: peer,
                    second: TestCredentials.dave
                )
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

                try await SubscriptionDance.assertNoSubscription(
                    harness: harness,
                    first: TestCredentials.alice,
                    second: TestCredentials.dave
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

                let added = try await harness.environment.rosterService.addContact(
                    jid: tempJID,
                    name: nil,
                    groups: [],
                    accountID: alice.accountID
                )

                #expect(added.isComplete)
                #expect(added.subscriptionStatus == .sent)
                #expect(harness.environment.rosterService.contact(jidString: tempJID.description, accountID: alice.accountID) != nil)
                #expect(try await harness.environment.store.fetchContacts(for: alice.accountID).contains { $0.jid == tempJID })

                let removed = try await harness.environment.rosterService.removeContact(
                    jidString: tempJID.description,
                    accountID: alice.accountID
                )

                #expect(removed.isComplete)
                #expect(harness.environment.rosterService.contact(jidString: tempJID.description, accountID: alice.accountID) == nil)
                #expect(try await !harness.environment.store.fetchContacts(for: alice.accountID).contains { $0.jid == tempJID })
            }
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

                try await SubscriptionDance.assertNoSubscription(
                    harness: harness,
                    first: TestCredentials.alice,
                    second: TestCredentials.dave
                )

                // Register cleanup before any roster mutation.
                harness.addCleanup { try? await daveRoster.removeContact(jid: aliceBareJID) }
                harness.addCleanup { try? await aliceRoster.removeContact(jid: daveBareJID) }

                // Alice adds Dave via service (which also subscribes).
                let addOutcome = try await harness.environment.rosterService.addContact(
                    jid: daveBareJID,
                    name: nil,
                    groups: [],
                    accountID: alice.accountID
                )
                #expect(addOutcome.isComplete)

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

                try await SubscriptionDance.assertNoSubscription(
                    harness: harness,
                    first: TestCredentials.alice,
                    second: TestCredentials.dave
                )

                // Register cleanup before any roster mutation.
                harness.addCleanup { try? await daveRoster.removeContact(jid: aliceBareJID) }
                harness.addCleanup { try? await aliceRoster.removeContact(jid: daveBareJID) }

                // Alice adds Dave via service (which also subscribes).
                let addOutcome = try await harness.environment.rosterService.addContact(
                    jid: daveBareJID,
                    name: nil,
                    groups: [],
                    accountID: alice.accountID
                )
                #expect(addOutcome.isComplete)

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
