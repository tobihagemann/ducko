import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

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
    struct StatusOptions {
        @Test func `selectableCases excludes offline in canonical order`() {
            #expect(PresenceService.PresenceStatus.selectableCases == [.available, .away, .xa, .dnd])
        }

        @Test func `allCases is the full canonical order including offline`() {
            #expect(PresenceService.PresenceStatus.allCases == [.available, .away, .xa, .dnd, .offline])
        }
    }

    struct PresenceUpdated {
        @Test
        @MainActor
        func `Presence updated sets contact status`() async throws {
            let service = makePresenceService()

            let presence = makePresence(show: .away)
            let from = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            await service.handleEvent(.presenceUpdated(from: from, presence: presence), accountID: testAccountID)

            #expect(service.contactPresences[contactJID] == .away)
        }

        @Test
        @MainActor
        func `Unavailable presence sets status to offline`() async throws {
            let service = makePresenceService()

            // First set to available
            let available = makePresence()
            let from = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            await service.handleEvent(.presenceUpdated(from: from, presence: available), accountID: testAccountID)
            #expect(service.contactPresences[contactJID] == .available)

            // Then unavailable — entry is removed (absent means offline)
            let unavailable = makePresence(type: .unavailable)
            await service.handleEvent(.presenceUpdated(from: from, presence: unavailable), accountID: testAccountID)
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
        func `Show values map correctly`(show: XMPPPresence.Show, expected: PresenceService.PresenceStatus) async throws {
            let service = makePresenceService()

            let presence = makePresence(show: show)
            let from = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            await service.handleEvent(.presenceUpdated(from: from, presence: presence), accountID: testAccountID)

            #expect(service.contactPresences[contactJID] == expected)
        }
    }

    struct SubscriptionRequests {
        @Test
        @MainActor
        func `Subscription request is stored`() async {
            let service = makePresenceService()

            await service.handleEvent(.presenceSubscriptionRequest(from: contactJID), accountID: testAccountID)

            #expect(service.pendingSubscriptionRequests.count == 1)
            #expect(service.pendingSubscriptionRequests[0] == contactJID)
        }

        @Test
        @MainActor
        func `Duplicate subscription request is not stored twice`() async {
            let service = makePresenceService()

            await service.handleEvent(.presenceSubscriptionRequest(from: contactJID), accountID: testAccountID)
            await service.handleEvent(.presenceSubscriptionRequest(from: contactJID), accountID: testAccountID)

            #expect(service.pendingSubscriptionRequests.count == 1)
        }
    }

    struct RemoveSubscriptionRequest {
        @Test
        @MainActor
        func `removeSubscriptionRequest removes matching JID`() async {
            let service = makePresenceService()

            await service.handleEvent(.presenceSubscriptionRequest(from: contactJID), accountID: testAccountID)
            #expect(service.pendingSubscriptionRequests.count == 1)

            service.removeSubscriptionRequest(contactJID, accountID: testAccountID)
            #expect(service.pendingSubscriptionRequests.isEmpty)
        }

        @Test
        @MainActor
        func `removeSubscriptionRequest does nothing for unknown JID`() async throws {
            let service = makePresenceService()
            let otherJID = try #require(BareJID(localPart: "other", domainPart: "example.com"))

            await service.handleEvent(.presenceSubscriptionRequest(from: contactJID), accountID: testAccountID)
            #expect(service.pendingSubscriptionRequests.count == 1)

            service.removeSubscriptionRequest(otherJID, accountID: testAccountID)
            #expect(service.pendingSubscriptionRequests.count == 1)
        }
    }

    struct Disconnect {
        @Test
        @MainActor
        func `Disconnect event clears contactPresences and pendingSubscriptionRequests`() async throws {
            let service = makePresenceService()

            // Set some presence and a pending subscription request
            let presence = makePresence(show: .away)
            let from = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            await service.handleEvent(.presenceUpdated(from: from, presence: presence), accountID: testAccountID)
            await service.handleEvent(.presenceSubscriptionRequest(from: contactJID), accountID: testAccountID)
            #expect(!service.contactPresences.isEmpty)
            #expect(!service.pendingSubscriptionRequests.isEmpty)

            // Disconnect should clear both
            await service.handleEvent(.disconnected(.requested), accountID: testAccountID)
            #expect(service.contactPresences.isEmpty)
            #expect(service.pendingSubscriptionRequests.isEmpty)
        }
    }

    struct MultiAccountIsolation {
        @Test
        @MainActor
        func `Disconnect clears only the disconnected account`() async throws {
            let service = makePresenceService()
            let account1 = UUID()
            let account2 = UUID()

            let from = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            let otherJID = try #require(BareJID(localPart: "other", domainPart: "example.com"))
            let otherFrom = try JID.full(#require(FullJID(bareJID: otherJID, resourcePart: "res")))

            // Account 1 gets presence + subscription
            await service.handleEvent(.presenceUpdated(from: from, presence: makePresence(show: .away)), accountID: account1)
            await service.handleEvent(.presenceSubscriptionRequest(from: contactJID), accountID: account1)

            // Account 2 gets presence + subscription
            await service.handleEvent(.presenceUpdated(from: otherFrom, presence: makePresence(show: .dnd)), accountID: account2)
            await service.handleEvent(.presenceSubscriptionRequest(from: otherJID), accountID: account2)

            #expect(service.contactPresences.count == 2)
            #expect(service.pendingSubscriptionRequests.count == 2)

            // Disconnect account 1 — account 2's state remains
            await service.handleEvent(.disconnected(.requested), accountID: account1)
            #expect(service.contactPresences.count == 1)
            #expect(service.contactPresences[otherJID] == .dnd)
            #expect(service.pendingSubscriptionRequests.count == 1)
            #expect(service.pendingSubscriptionRequests[0] == otherJID)
        }

        @Test
        @MainActor
        func `Aggregate contactPresences merges all accounts`() async throws {
            let service = makePresenceService()
            let account1 = UUID()
            let account2 = UUID()

            let from = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            let otherJID = try #require(BareJID(localPart: "other", domainPart: "example.com"))
            let otherFrom = try JID.full(#require(FullJID(bareJID: otherJID, resourcePart: "res")))

            await service.handleEvent(.presenceUpdated(from: from, presence: makePresence(show: .away)), accountID: account1)
            await service.handleEvent(.presenceUpdated(from: otherFrom, presence: makePresence(show: .xa)), accountID: account2)

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

        /// Locks in the optimistic-update contract: `applyPresence` must
        /// mutate `myPresence` and `myStatusMessage` BEFORE its first
        /// suspension point. SwiftUI views (and AX-driven consumers reading
        /// `kAXValueAttribute` on a `Picker.menu`) rely on this so the new
        /// state is visible without waiting for a network round-trip.
        @Test
        @MainActor
        func `applyPresence updates myPresence before awaiting connect`() async {
            let service = makePresenceService()
            service.goOffline(accountID: testAccountID)
            #expect(service.myPresence == .offline)

            let connectStarted = AsyncSemaphore()
            let releaseConnect = AsyncSemaphore()

            let task = Task { @MainActor in
                await service.applyPresence(
                    .available,
                    message: "back",
                    accountID: testAccountID,
                    connect: { _ in
                        await connectStarted.signal()
                        await releaseConnect.wait()
                    },
                    disconnect: { _ in }
                )
            }

            // Wait for connect to be entered — by then myPresence and
            // myStatusMessage must already reflect the new values.
            await connectStarted.wait()
            #expect(service.myPresence == .available)
            #expect(service.myStatusMessage == "back")

            await releaseConnect.signal()
            await task.value
        }
    }

    struct ConnectionStateClassification {
        @Test(arguments: [
            (AccountService.ConnectionState?.none, true),
            (.some(.disconnected), true),
            (.some(.error("oops")), true),
            (.some(.connecting), false),
            (.some(.connected(FullJID(bareJID: contactJID, resourcePart: "res")!)), false)
        ] as [(AccountService.ConnectionState?, Bool)])
        func `isDisconnected classifies every ConnectionState case`(
            state: AccountService.ConnectionState?,
            expected: Bool
        ) {
            #expect(PresenceService.isDisconnected(state: state) == expected)
        }
    }
}

// MARK: - Test Helpers

/// Counting permit-based async semaphore used to gate test progress at a
/// specific suspension point inside the system under test. `signal` before
/// any `wait` increments a permit so the next `wait` returns immediately —
/// signals are never dropped.
private actor AsyncSemaphore {
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var permits = 0

    func signal() {
        if let next = pending.first {
            pending.removeFirst()
            next.resume()
        } else {
            permits += 1
        }
    }

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            pending.append(continuation)
        }
    }
}
