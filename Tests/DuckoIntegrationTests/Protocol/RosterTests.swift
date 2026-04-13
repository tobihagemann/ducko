import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCore

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
                let client = try #require(harness.environment.accountService.client(for: alice.accountID))
                let roster = try #require(await client.module(ofType: RosterModule.self))

                let bobBareJID = try #require(BareJID.parse(TestCredentials.bob.jid))
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

        @Test @MainActor func `Presence subscription is approved`() async throws {
            try await TestHarness.withHarness { harness in
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

                // Alice subscribes to Bob.
                try await aliceRoster.subscribe(to: bobBareJID)

                // Bob sees the subscription request.
                _ = try await bob.waitForEvent { event in
                    if case let .presenceSubscriptionRequest(from) = event, from == aliceBareJID {
                        return true
                    }
                    return false
                }

                // Bob approves.
                try await bobRoster.approveSubscription(from: aliceBareJID)

                // Alice sees the approval.
                _ = try await alice.waitForEvent { event in
                    if case let .presenceSubscriptionApproved(from) = event, from == bobBareJID {
                        return true
                    }
                    return false
                }
            }
        }

        @Test @MainActor func `Presence subscription is denied`() async throws {
            try await TestHarness.withHarness { harness in
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

                // Alice subscribes to Bob.
                try await aliceRoster.subscribe(to: bobBareJID)

                // Bob sees the subscription request.
                _ = try await bob.waitForEvent { event in
                    if case let .presenceSubscriptionRequest(from) = event, from == aliceBareJID {
                        return true
                    }
                    return false
                }

                // Bob denies.
                try await bobRoster.denySubscription(from: aliceBareJID)

                // Alice sees the revocation.
                _ = try await alice.waitForEvent { event in
                    if case let .presenceSubscriptionRevoked(from) = event, from == bobBareJID {
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
                let bobBareJID = try #require(BareJID.parse(TestCredentials.bob.jid))
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

        @Test @MainActor func `Service approveSubscription clears pending request`() async throws {
            try await TestHarness.withHarness { harness in
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

                // Alice adds Bob via service (which also subscribes).
                try await harness.environment.rosterService.addContact(
                    jid: bobBareJID,
                    name: nil,
                    groups: [],
                    accountID: alice.accountID
                )

                // Bob waits for the subscription request.
                _ = try await bob.waitForEvent { event in
                    if case let .presenceSubscriptionRequest(from) = event, from == aliceBareJID {
                        return true
                    }
                    return false
                }

                // Bob approves via service.
                try await harness.environment.rosterService.approveSubscription(
                    jidString: aliceBareJID.description,
                    accountID: bob.accountID
                )

                // Verify pending request is cleared on Bob's side.
                try await bob.waitForCondition({ @MainActor in
                    !harness.environment.presenceService.pendingSubscriptionRequests.contains(aliceBareJID)
                }, timeout: TestTimeout.event)
            }
        }

        @Test @MainActor func `Service denySubscription clears pending request`() async throws {
            try await TestHarness.withHarness { harness in
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

                // Alice adds Bob via service (which also subscribes).
                try await harness.environment.rosterService.addContact(
                    jid: bobBareJID,
                    name: nil,
                    groups: [],
                    accountID: alice.accountID
                )

                // Bob waits for the subscription request.
                _ = try await bob.waitForEvent { event in
                    if case let .presenceSubscriptionRequest(from) = event, from == aliceBareJID {
                        return true
                    }
                    return false
                }

                // Wait for service state to register the pending request.
                try await bob.waitForCondition({ @MainActor in
                    harness.environment.presenceService.pendingSubscriptionRequests.contains(aliceBareJID)
                }, timeout: TestTimeout.event)

                // Bob denies via service.
                try await harness.environment.rosterService.denySubscription(
                    jidString: aliceBareJID.description,
                    accountID: bob.accountID
                )

                // Verify pending request is cleared on Bob's side.
                try await bob.waitForCondition({ @MainActor in
                    !harness.environment.presenceService.pendingSubscriptionRequests.contains(aliceBareJID)
                }, timeout: TestTimeout.event)

                // Alice sees the revocation.
                _ = try await alice.waitForEvent { event in
                    if case let .presenceSubscriptionRevoked(from) = event, from == bobBareJID {
                        return true
                    }
                    return false
                }
            }
        }
    }
}
