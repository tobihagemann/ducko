import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// MARK: - Helpers

private let testAccountID = UUID()
private let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!

private struct MockIdleTimeSource: IdleTimeSource {
    var idleSeconds: TimeInterval

    func secondsSinceLastUserInput() -> TimeInterval {
        idleSeconds
    }
}

@MainActor
private func makePresenceService(idleTimeSource: any IdleTimeSource = MockIdleTimeSource(idleSeconds: 0)) -> PresenceService {
    PresenceService(idleTimeSource: idleTimeSource)
}

private func makePresence(show: XMPPPresence.Show? = nil, type: XMPPPresence.PresenceType? = nil) -> XMPPPresence {
    var presence = XMPPPresence(type: type)
    presence.show = show
    return presence
}

// MARK: - Tests

enum PresenceServiceTests {
    struct PresenceUpdated {
        @Test
        @MainActor
        func `Presence updated sets contact status`() throws {
            let service = makePresenceService()

            let presence = makePresence(show: .away)
            let from = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            service.handleEvent(.presenceUpdated(from: from, presence: presence), accountID: testAccountID)

            #expect(service.contactPresences[contactJID] == .away)
        }

        @Test
        @MainActor
        func `Unavailable presence sets status to offline`() throws {
            let service = makePresenceService()

            // First set to available
            let available = makePresence()
            let from = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            service.handleEvent(.presenceUpdated(from: from, presence: available), accountID: testAccountID)
            #expect(service.contactPresences[contactJID] == .available)

            // Then unavailable — entry is removed (absent means offline)
            let unavailable = makePresence(type: .unavailable)
            service.handleEvent(.presenceUpdated(from: from, presence: unavailable), accountID: testAccountID)
            #expect(service.contactPresences[contactJID] == nil)
        }

        @Test(
            arguments: [
                (XMPPPresence.Show.chat, PresenceService.PresenceStatus.available),
                (XMPPPresence.Show.away, PresenceService.PresenceStatus.away),
                (XMPPPresence.Show.xa, PresenceService.PresenceStatus.xa),
                (XMPPPresence.Show.dnd, PresenceService.PresenceStatus.dnd)
            ] as [(XMPPPresence.Show, PresenceService.PresenceStatus)]
        )
        @MainActor
        func `Show values map correctly`(show: XMPPPresence.Show, expected: PresenceService.PresenceStatus) throws {
            let service = makePresenceService()

            let presence = makePresence(show: show)
            let from = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            service.handleEvent(.presenceUpdated(from: from, presence: presence), accountID: testAccountID)

            #expect(service.contactPresences[contactJID] == expected)
        }
    }

    struct SubscriptionRequests {
        @Test
        @MainActor
        func `Subscription request is stored`() {
            let service = makePresenceService()

            service.handleEvent(.presenceSubscriptionRequest(from: contactJID), accountID: testAccountID)

            #expect(service.pendingSubscriptionRequests.count == 1)
            #expect(service.pendingSubscriptionRequests[0] == contactJID)
        }

        @Test
        @MainActor
        func `Duplicate subscription request is not stored twice`() {
            let service = makePresenceService()

            service.handleEvent(.presenceSubscriptionRequest(from: contactJID), accountID: testAccountID)
            service.handleEvent(.presenceSubscriptionRequest(from: contactJID), accountID: testAccountID)

            #expect(service.pendingSubscriptionRequests.count == 1)
        }
    }

    struct RemoveSubscriptionRequest {
        @Test
        @MainActor
        func `removeSubscriptionRequest removes matching JID`() {
            let service = makePresenceService()

            service.handleEvent(.presenceSubscriptionRequest(from: contactJID), accountID: testAccountID)
            #expect(service.pendingSubscriptionRequests.count == 1)

            service.removeSubscriptionRequest(contactJID, accountID: testAccountID)
            #expect(service.pendingSubscriptionRequests.isEmpty)
        }

        @Test
        @MainActor
        func `removeSubscriptionRequest does nothing for unknown JID`() throws {
            let service = makePresenceService()
            let otherJID = try #require(BareJID(localPart: "other", domainPart: "example.com"))

            service.handleEvent(.presenceSubscriptionRequest(from: contactJID), accountID: testAccountID)
            #expect(service.pendingSubscriptionRequests.count == 1)

            service.removeSubscriptionRequest(otherJID, accountID: testAccountID)
            #expect(service.pendingSubscriptionRequests.count == 1)
        }
    }

    struct Disconnect {
        @Test
        @MainActor
        func `Disconnect event clears contactPresences and pendingSubscriptionRequests`() throws {
            let service = makePresenceService()

            // Set some presence and a pending subscription request
            let presence = makePresence(show: .away)
            let from = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            service.handleEvent(.presenceUpdated(from: from, presence: presence), accountID: testAccountID)
            service.handleEvent(.presenceSubscriptionRequest(from: contactJID), accountID: testAccountID)
            #expect(!service.contactPresences.isEmpty)
            #expect(!service.pendingSubscriptionRequests.isEmpty)

            // Disconnect should clear both
            service.handleEvent(.disconnected(.requested), accountID: testAccountID)
            #expect(service.contactPresences.isEmpty)
            #expect(service.pendingSubscriptionRequests.isEmpty)
        }
    }

    struct MultiAccountIsolation {
        @Test
        @MainActor
        func `Disconnect clears only the disconnected account`() throws {
            let service = makePresenceService()
            let account1 = UUID()
            let account2 = UUID()

            let from = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            let otherJID = try #require(BareJID(localPart: "other", domainPart: "example.com"))
            let otherFrom = try JID.full(#require(FullJID(bareJID: otherJID, resourcePart: "res")))

            // Account 1 gets presence + subscription
            service.handleEvent(.presenceUpdated(from: from, presence: makePresence(show: .away)), accountID: account1)
            service.handleEvent(.presenceSubscriptionRequest(from: contactJID), accountID: account1)

            // Account 2 gets presence + subscription
            service.handleEvent(.presenceUpdated(from: otherFrom, presence: makePresence(show: .dnd)), accountID: account2)
            service.handleEvent(.presenceSubscriptionRequest(from: otherJID), accountID: account2)

            #expect(service.contactPresences.count == 2)
            #expect(service.pendingSubscriptionRequests.count == 2)

            // Disconnect account 1 — account 2's state remains
            service.handleEvent(.disconnected(.requested), accountID: account1)
            #expect(service.contactPresences.count == 1)
            #expect(service.contactPresences[otherJID] == .dnd)
            #expect(service.pendingSubscriptionRequests.count == 1)
            #expect(service.pendingSubscriptionRequests[0] == otherJID)
        }

        @Test
        @MainActor
        func `Aggregate contactPresences merges all accounts`() throws {
            let service = makePresenceService()
            let account1 = UUID()
            let account2 = UUID()

            let from = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            let otherJID = try #require(BareJID(localPart: "other", domainPart: "example.com"))
            let otherFrom = try JID.full(#require(FullJID(bareJID: otherJID, resourcePart: "res")))

            service.handleEvent(.presenceUpdated(from: from, presence: makePresence(show: .away)), accountID: account1)
            service.handleEvent(.presenceUpdated(from: otherFrom, presence: makePresence(show: .xa)), accountID: account2)

            #expect(service.contactPresences[contactJID] == .away)
            #expect(service.contactPresences[otherJID] == .xa)
        }
    }

    struct StatusDisplayName {
        @Test(
            arguments: [
                (PresenceService.PresenceStatus.available, "Available"),
                (PresenceService.PresenceStatus.away, "Away"),
                (PresenceService.PresenceStatus.xa, "Extended Away"),
                (PresenceService.PresenceStatus.dnd, "Do Not Disturb"),
                (PresenceService.PresenceStatus.offline, "Offline")
            ] as [(PresenceService.PresenceStatus, String)]
        )
        func `PresenceStatus displayName returns human-readable string`(status: PresenceService.PresenceStatus, expected: String) {
            #expect(status.displayName == expected)
        }
    }

    struct MyPresence {
        @Test
        @MainActor
        func `goOffline sets status to offline`() {
            let service = makePresenceService()
            #expect(service.myPresence == .available)

            service.goOffline(accountID: testAccountID)
            #expect(service.myPresence == .offline)
        }
    }
}
