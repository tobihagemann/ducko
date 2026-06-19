import DuckoTestSupport
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

private func makePresence(show: XMPPPresence.Show? = nil, type: XMPPPresence.PresenceType? = nil, status: String? = nil) -> XMPPPresence {
    var presence = XMPPPresence(type: type)
    presence.show = show
    presence.status = status
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

    struct PeerStatusMessages {
        @Test
        @MainActor
        func `Custom status text is captured and trimmed`() async throws {
            let service = makePresenceService()
            let from = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))

            await service.handleEvent(
                .presenceUpdated(from: from, presence: makePresence(show: .away, status: "  Out to lunch  ")),
                accountID: testAccountID
            )

            #expect(service.statusMessage(for: contactJID) == "Out to lunch")
            #expect(service.contactStatusMessages[contactJID] == "Out to lunch")
        }

        @Test
        @MainActor
        func `Returning to plain available clears the stale status`() async throws {
            let service = makePresenceService()
            let from = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))

            await service.handleEvent(
                .presenceUpdated(from: from, presence: makePresence(status: "Busy")),
                accountID: testAccountID
            )
            try #require(service.statusMessage(for: contactJID) == "Busy")

            // Plain available with no status text must drop the prior custom status.
            await service.handleEvent(
                .presenceUpdated(from: from, presence: makePresence()),
                accountID: testAccountID
            )
            #expect(service.statusMessage(for: contactJID) == nil)
        }

        @Test
        @MainActor
        func `Whitespace-only status clears the entry`() async throws {
            let service = makePresenceService()
            let from = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))

            await service.handleEvent(
                .presenceUpdated(from: from, presence: makePresence(status: "Here")),
                accountID: testAccountID
            )
            try #require(service.statusMessage(for: contactJID) == "Here")

            await service.handleEvent(
                .presenceUpdated(from: from, presence: makePresence(status: "   ")),
                accountID: testAccountID
            )
            #expect(service.statusMessage(for: contactJID) == nil)
        }

        @Test
        @MainActor
        func `Going offline clears the status even with status text present`() async throws {
            let service = makePresenceService()
            let from = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))

            await service.handleEvent(
                .presenceUpdated(from: from, presence: makePresence(status: "Away a while")),
                accountID: testAccountID
            )
            try #require(service.statusMessage(for: contactJID) == "Away a while")

            // Some servers send a status on the unavailable stanza; offline must still clear it.
            await service.handleEvent(
                .presenceUpdated(from: from, presence: makePresence(type: .unavailable, status: "Away a while")),
                accountID: testAccountID
            )
            #expect(service.statusMessage(for: contactJID) == nil)
        }

        @Test
        @MainActor
        func `Disconnect clears captured status messages for the account`() async throws {
            let service = makePresenceService()
            let from = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))

            await service.handleEvent(
                .presenceUpdated(from: from, presence: makePresence(status: "Working")),
                accountID: testAccountID
            )
            try #require(!service.contactStatusMessages.isEmpty)

            await service.handleEvent(.disconnected(.requested), accountID: testAccountID)
            #expect(service.contactStatusMessages.isEmpty)
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

    struct AccountScopedReads {
        @Test
        @MainActor
        func `presence(for:accountID:) resolves the requested account when the JID is on two`() async throws {
            let service = makePresenceService()
            let account1 = UUID()
            let account2 = UUID()
            let from = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))

            await service.handleEvent(.presenceUpdated(from: from, presence: makePresence(show: .away)), accountID: account1)
            await service.handleEvent(.presenceUpdated(from: from, presence: makePresence(show: .dnd)), accountID: account2)

            #expect(service.presence(for: contactJID, accountID: account1) == .away)
            #expect(service.presence(for: contactJID, accountID: account2) == .dnd)
        }

        @Test
        @MainActor
        func `presence(for:accountID:) returns nil for a JID on a different account`() async throws {
            let service = makePresenceService()
            let account1 = UUID()
            let account2 = UUID()
            let from = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))

            await service.handleEvent(.presenceUpdated(from: from, presence: makePresence(show: .away)), accountID: account1)

            #expect(service.presence(for: contactJID, accountID: account2) == nil)
        }

        @Test
        @MainActor
        func `statusMessage(for:accountID:) resolves the requested account and returns nil elsewhere`() async throws {
            let service = makePresenceService()
            let account1 = UUID()
            let account2 = UUID()
            let from = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))

            await service.handleEvent(.presenceUpdated(from: from, presence: makePresence(status: "On A")), accountID: account1)
            await service.handleEvent(.presenceUpdated(from: from, presence: makePresence(status: "On B")), accountID: account2)

            #expect(service.statusMessage(for: contactJID, accountID: account1) == "On A")
            #expect(service.statusMessage(for: contactJID, accountID: account2) == "On B")
            #expect(service.statusMessage(for: contactJID, accountID: UUID()) == nil)
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

    struct IdleBroadcast {
        @Test
        @MainActor
        func `broadcasts the held presence to every connected account, and nothing while offline`() async throws {
            let store = MockPersistenceStore()
            let credentials = MockCredentialStore()
            let aliceTransport = MockTransport()
            let bobTransport = MockTransport()
            let factory = MockXMPPClientFactory(
                transportForAccount: { $0.jid.localPart == "alice" ? aliceTransport : bobTransport },
                modulesForAccount: { _ in [PresenceModule(), CapsModule()] }
            )
            let accountService = AccountService(store: store, credentialStore: credentials, clientFactory: factory)
            let presenceService = PresenceService()
            presenceService.setAccountService(accountService)

            let aliceID = try await accountService.createAccount(jidString: "alice@example.com", host: "example.com", port: 5222)
            let bobID = try await accountService.createAccount(jidString: "bob@example.com", host: "example.com", port: 5222)
            let (_, aliceTask) = try await driveMockConnect(accountService, accountID: aliceID, transport: aliceTransport, awaitInitialPresence: true)
            let (_, bobTask) = try await driveMockConnect(accountService, accountID: bobID, transport: bobTransport, awaitInitialPresence: true)

            await aliceTransport.clearSentBytes()
            await bobTransport.clearSentBytes()

            // Auto-away: a held away status reaches both connected accounts.
            presenceService.myPresence = .away
            await presenceService.broadcastPresenceToConnectedAccounts()

            let awayAlice = await aliceTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            let awayBob = await bobTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(awayAlice.contains { $0.contains("<presence") && $0.contains("away") })
            #expect(awayBob.contains { $0.contains("<presence") && $0.contains("away") })

            // Offline: the broadcast emits no presence, so an offline user is never shown as away on the
            // still-connected accounts (the broadcast half of the offline guard; the activation half lives
            // in the un-injectable 30 s idle-monitor loop).
            await aliceTransport.clearSentBytes()
            await bobTransport.clearSentBytes()
            presenceService.myPresence = .offline
            await presenceService.broadcastPresenceToConnectedAccounts()

            let offlineAlice = await aliceTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            let offlineBob = await bobTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(offlineAlice.allSatisfy { !$0.contains("<presence") })
            #expect(offlineBob.allSatisfy { !$0.contains("<presence") })

            aliceTask.cancel()
            bobTask.cancel()
            await accountService.disconnect(accountID: aliceID)
            await accountService.disconnect(accountID: bobID)
        }

        @Test
        @MainActor
        func `an idle transition broadcasts the resulting presence to a connected account`() async throws {
            let store = MockPersistenceStore()
            let credentials = MockCredentialStore()
            let transport = MockTransport()
            let factory = MockXMPPClientFactory(
                transportForAccount: { _ in transport },
                modulesForAccount: { _ in [PresenceModule(), CapsModule()] }
            )
            let accountService = AccountService(store: store, credentialStore: credentials, clientFactory: factory)
            let presenceService = PresenceService()
            presenceService.setAccountService(accountService)

            let accountID = try await accountService.createAccount(jidString: "alice@example.com", host: "example.com", port: 5222)
            let (_, task) = try await driveMockConnect(accountService, accountID: accountID, transport: transport, awaitInitialPresence: true)
            await transport.clearSentBytes()

            // Idling past the timeout must drive the transition AND broadcast the resulting away presence.
            await presenceService.applyIdleTransition(idleTime: 400, timeout: 300)
            let awaySent = await transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(awaySent.contains { $0.contains("<presence") && $0.contains("away") })

            // Returning to activity must broadcast the restored presence.
            await transport.clearSentBytes()
            await presenceService.applyIdleTransition(idleTime: 0, timeout: 300)
            let restoreSent = await transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(restoreSent.contains { $0.contains("<presence") })

            task.cancel()
            await accountService.disconnect(accountID: accountID)
        }
    }

    struct IdleTransitions {
        @Test
        @MainActor
        func `idle past timeout activates auto-away from the held presence`() async {
            let service = makePresenceService()
            #expect(service.myPresence == .available)
            await service.applyIdleTransition(idleTime: 400, timeout: 300)
            #expect(service.myPresence == .away)
        }

        @Test
        @MainActor
        func `return to activity restores the held presence`() async {
            let service = makePresenceService()
            service.myPresence = .dnd
            await service.applyIdleTransition(idleTime: 400, timeout: 300)
            #expect(service.myPresence == .away)
            await service.applyIdleTransition(idleTime: 0, timeout: 300)
            #expect(service.myPresence == .dnd)
        }

        @Test
        @MainActor
        func `idle does not promote a deliberately offline user to away`() async {
            let service = makePresenceService()
            service.goOffline(accountID: UUID())
            #expect(service.myPresence == .offline)
            await service.applyIdleTransition(idleTime: 400, timeout: 300)
            #expect(service.myPresence == .offline)
        }

        @Test
        @MainActor
        func `going offline during auto-away cancels the pending restore`() async {
            let service = makePresenceService()
            // Idle activates auto-away, holding the prior Available.
            await service.applyIdleTransition(idleTime: 400, timeout: 300)
            #expect(service.myPresence == .away)
            // The user deliberately goes Offline while still idle.
            service.goOffline(accountID: UUID())
            #expect(service.myPresence == .offline)
            // Returning to activity must not undo the deliberate Offline.
            await service.applyIdleTransition(idleTime: 0, timeout: 300)
            #expect(service.myPresence == .offline)
        }

        @Test
        @MainActor
        func `a manual status change during auto-away survives the idle return`() async {
            let service = makePresenceService()
            // Idle activates auto-away, holding the prior Available.
            await service.applyIdleTransition(idleTime: 400, timeout: 300)
            #expect(service.myPresence == .away)
            // The user manually picks a non-offline status while still idle.
            await service.setPresence(.dnd, message: nil, accountID: testAccountID)
            #expect(service.myPresence == .dnd)
            // Returning to activity must not clobber the manual choice with the stale held presence.
            await service.applyIdleTransition(idleTime: 0, timeout: 300)
            #expect(service.myPresence == .dnd)
        }

        @Test
        @MainActor
        func `a status change via the GUI applyPresence path during auto-away survives the idle return`() async {
            let service = makePresenceService()
            // Idle activates auto-away, holding the prior Available.
            await service.applyIdleTransition(idleTime: 400, timeout: 300)
            #expect(service.myPresence == .away)
            // The user picks a non-offline status through the GUI path (StatusBarView/MenuBarStatusView → applyPresence).
            await service.applyPresence(.dnd, message: nil, accountID: testAccountID, connect: { _ in }, disconnect: { _ in })
            #expect(service.myPresence == .dnd)
            // Returning to activity must not clobber the GUI choice with the stale held presence.
            await service.applyIdleTransition(idleTime: 0, timeout: 300)
            #expect(service.myPresence == .dnd)
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

    struct GlobalAndAccountPresence {
        @Test
        @MainActor
        func `applyGlobalPresence broadcasts to every connected account and clears overrides`() async throws {
            let fixture = try await makeTwoConnectedAccounts()
            let service = fixture.presenceService

            // Pin Bob to DND, then clear the wire so the global broadcast is isolated.
            await service.applyAccountPresence(.dnd, message: "busy", accountID: fixture.bobID, connect: { _ in }, disconnect: { _ in })
            #expect(service.effectiveStatus(for: fixture.bobID) == .dnd)
            await fixture.aliceTransport.clearSentBytes()
            await fixture.bobTransport.clearSentBytes()

            await service.applyGlobalPresence(.away, message: nil, identityAccountID: nil) { id in
                try await fixture.accountService.connect(accountID: id)
            } disconnect: { id in
                await fixture.accountService.disconnect(accountID: id)
            }

            let alice = await fixture.aliceTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            let bob = await fixture.bobTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(alice.contains { $0.contains("<presence") && $0.contains("away") })
            #expect(bob.contains { $0.contains("<presence") && $0.contains("away") })
            #expect(service.effectiveStatus(for: fixture.bobID) == .away)

            await fixture.teardown()
        }

        @Test
        @MainActor
        func `applyAccountPresence pins one account and a later global resets everyone`() async throws {
            let fixture = try await makeTwoConnectedAccounts()
            let service = fixture.presenceService
            await fixture.aliceTransport.clearSentBytes()
            await fixture.bobTransport.clearSentBytes()

            await service.applyAccountPresence(.dnd, message: "busy", accountID: fixture.bobID) { id in
                try await fixture.accountService.connect(accountID: id)
            } disconnect: { id in
                await fixture.accountService.disconnect(accountID: id)
            }

            let bob = await fixture.bobTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            let alice = await fixture.aliceTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(bob.contains { $0.contains("<presence") && $0.contains("dnd") && $0.contains("busy") })
            #expect(alice.allSatisfy { !$0.contains("<presence") })
            #expect(service.effectiveStatus(for: fixture.bobID) == .dnd)
            #expect(service.effectivePresence(for: fixture.bobID).message == "busy")
            #expect(service.effectiveStatus(for: fixture.aliceID) == .available)

            await service.applyGlobalPresence(.available, message: nil, identityAccountID: nil, connect: { _ in }, disconnect: { _ in })
            #expect(service.effectiveStatus(for: fixture.bobID) == .available)

            await fixture.teardown()
        }

        @Test
        @MainActor
        func `applyAccountPresence offline stores no override and disconnects only that account`() async throws {
            let fixture = try await makeTwoConnectedAccounts()
            let service = fixture.presenceService

            // Pre-pin Bob so the assertion proves the override is dropped, not stored as an offline override.
            await service.applyAccountPresence(.dnd, message: nil, accountID: fixture.bobID, connect: { _ in }, disconnect: { _ in })
            #expect(service.effectiveStatus(for: fixture.bobID) == .dnd)

            await service.applyAccountPresence(.offline, message: nil, accountID: fixture.bobID) { id in
                try await fixture.accountService.connect(accountID: id)
            } disconnect: { id in
                await fixture.accountService.disconnect(accountID: id)
            }

            // Effective falls back to the global Available — not Offline — so no override lingers.
            #expect(service.effectiveStatus(for: fixture.bobID) == .available)
            #expect(fixture.accountService.connectedClient(for: fixture.bobID) == nil)
            #expect(fixture.accountService.connectedClient(for: fixture.aliceID) != nil)

            await fixture.teardown()
        }

        @Test
        @MainActor
        func `a user-initiated AccountService disconnect clears the account override`() async throws {
            let fixture = try await makeTwoConnectedAccounts()
            let service = fixture.presenceService

            await service.applyAccountPresence(.dnd, message: nil, accountID: fixture.bobID, connect: { _ in }, disconnect: { _ in })
            #expect(service.effectiveStatus(for: fixture.bobID) == .dnd)

            // A deliberate disconnect must drop the pin even though the cancelled event task never delivers
            // `.disconnected(.requested)` to `handleEvent`.
            await fixture.accountService.disconnect(accountID: fixture.bobID)
            #expect(service.effectiveStatus(for: fixture.bobID) == .available)

            await fixture.teardown()
        }

        @Test
        @MainActor
        func `an override survives a connection-lost disconnect and is dropped by a requested one`() async {
            let service = makePresenceService()
            let accountID = UUID()
            await service.applyAccountPresence(.dnd, message: nil, accountID: accountID, connect: { _ in }, disconnect: { _ in })
            #expect(service.effectiveStatus(for: accountID) == .dnd)

            await service.handleEvent(.disconnected(.connectionLost("dropped")), accountID: accountID)
            #expect(service.effectiveStatus(for: accountID) == .dnd)

            await service.handleEvent(.disconnected(.requested), accountID: accountID)
            #expect(service.effectiveStatus(for: accountID) == .available)
        }

        @Test
        @MainActor
        func `effectivePresence returns global without an override and the override when set`() async {
            let service = makePresenceService()
            let accountID = UUID()
            #expect(service.effectivePresence(for: accountID).status == .available)
            #expect(service.effectivePresence(for: accountID).message == nil)

            await service.applyAccountPresence(.dnd, message: "busy", accountID: accountID, connect: { _ in }, disconnect: { _ in })
            #expect(service.effectivePresence(for: accountID).status == .dnd)
            #expect(service.effectivePresence(for: accountID).message == "busy")
            #expect(service.effectiveStatus(for: accountID) == .dnd)
        }
    }

    struct OverrideIdleAndReapply {
        @Test
        @MainActor
        func `idle auto-away leaves a per-account override untouched`() async throws {
            let fixture = try await makeTwoConnectedAccounts()
            let service = fixture.presenceService

            await service.applyAccountPresence(.dnd, message: nil, accountID: fixture.bobID, connect: { _ in }, disconnect: { _ in })
            await fixture.aliceTransport.clearSentBytes()
            await fixture.bobTransport.clearSentBytes()

            await service.applyIdleTransition(idleTime: 400, timeout: 300)
            let aliceAway = await fixture.aliceTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            let bobAway = await fixture.bobTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(aliceAway.contains { $0.contains("<presence") && $0.contains("away") })
            #expect(bobAway.allSatisfy { !$0.contains("away") })
            #expect(service.effectiveStatus(for: fixture.bobID) == .dnd)

            await service.applyIdleTransition(idleTime: 0, timeout: 300)
            #expect(service.myPresence == .available)
            #expect(service.effectiveStatus(for: fixture.bobID) == .dnd)

            await fixture.teardown()
        }

        @Test
        @MainActor
        func `reconnect reapplies an account override rather than a blank available`() async throws {
            let fixture = try await makeTwoConnectedAccounts()
            let service = fixture.presenceService

            // Global stays plain Available; only Bob carries a DND override.
            await service.applyAccountPresence(.dnd, message: nil, accountID: fixture.bobID, connect: { _ in }, disconnect: { _ in })
            await fixture.bobTransport.clearSentBytes()

            let bobBare = try #require(BareJID(localPart: "bob", domainPart: "example.com"))
            let bobFullJID = try #require(FullJID(bareJID: bobBare, resourcePart: "ducko"))
            await service.handleEvent(.connected(bobFullJID), accountID: fixture.bobID)

            let bob = await fixture.bobTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(bob.contains { $0.contains("<presence") && $0.contains("dnd") })

            await fixture.teardown()
        }

        @Test
        @MainActor
        func `resendEffectivePresence re-broadcasts an account override, not the global status`() async throws {
            // The path AvatarService uses for avatar/vCard/MUC re-broadcasts: it must carry the override.
            let fixture = try await makeTwoConnectedAccounts()
            let service = fixture.presenceService

            await service.applyAccountPresence(.dnd, message: nil, accountID: fixture.bobID, connect: { _ in }, disconnect: { _ in })
            await fixture.bobTransport.clearSentBytes()

            await service.resendEffectivePresence(accountID: fixture.bobID)

            let bob = await fixture.bobTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(bob.contains { $0.contains("<presence") && $0.contains("dnd") })

            await fixture.teardown()
        }
    }

    struct GlobalPresenceLifecycle {
        @Test
        @MainActor
        func `global offline tears down a connecting account too`() async throws {
            let store = MockPersistenceStore()
            let credentials = MockCredentialStore()
            let aliceTransport = MockTransport()
            let bobTransport = MockTransport()
            let factory = MockXMPPClientFactory(
                transportForAccount: { $0.jid.localPart == "alice" ? aliceTransport : bobTransport },
                modulesForAccount: { _ in [PresenceModule(), CapsModule()] }
            )
            let accountService = AccountService(store: store, credentialStore: credentials, clientFactory: factory)
            let presenceService = PresenceService()
            presenceService.setAccountService(accountService)

            let aliceID = try await accountService.createAccount(jidString: "alice@example.com", host: "example.com", port: 5222)
            let bobID = try await accountService.createAccount(jidString: "bob@example.com", host: "example.com", port: 5222)
            let (_, aliceTask) = try await driveMockConnect(accountService, accountID: aliceID, transport: aliceTransport, awaitInitialPresence: true)

            // Bob begins connecting but never finishes the handshake, so it stays `.connecting`.
            let bobTask = Task { @MainActor in try await accountService.connect(accountID: bobID, password: "secret") }
            for _ in 0 ..< 100 {
                if isConnecting(accountService.connectionStates[bobID]) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(isConnecting(accountService.connectionStates[bobID]))

            let recorder = CallRecorder()
            await presenceService.applyGlobalPresence(.offline, message: nil, identityAccountID: nil) { _ in
            } disconnect: { id in
                recorder.append(id)
                await accountService.disconnect(accountID: id)
            }

            #expect(Set(recorder.ids) == Set([aliceID, bobID]))
            #expect(presenceService.myPresence == .offline)

            aliceTask.cancel()
            bobTask.cancel()
        }

        @Test
        @MainActor
        func `going online from offline reconnects only connect-on-launch accounts`() async throws {
            let (accountService, presenceService) = makeUnconnectedService()
            let aliceID = try await accountService.createAccount(jidString: "alice@example.com", connectOnLaunch: true)
            let carolID = try await accountService.createAccount(jidString: "carol@example.com", connectOnLaunch: false)

            let recorder = CallRecorder()
            await presenceService.applyGlobalPresence(.available, message: nil, identityAccountID: nil) { id in
                recorder.append(id)
            } disconnect: { _ in }

            #expect(recorder.ids == [aliceID])
            #expect(!recorder.ids.contains(carolID))
        }

        @Test
        @MainActor
        func `going online with no connect-on-launch account falls back to the identity account`() async throws {
            let (accountService, presenceService) = makeUnconnectedService()
            let daveID = try await accountService.createAccount(jidString: "dave@example.com", connectOnLaunch: false)
            let eveID = try await accountService.createAccount(jidString: "eve@example.com", connectOnLaunch: false)

            let recorder = CallRecorder()
            await presenceService.applyGlobalPresence(.available, message: nil, identityAccountID: daveID) { id in
                recorder.append(id)
            } disconnect: { _ in }

            #expect(recorder.ids == [daveID])
            #expect(!recorder.ids.contains(eveID))
        }
    }
}

// MARK: - Multi-Account Fixtures

/// Records the account IDs a `connect`/`disconnect` closure was invoked for. A `@MainActor` class so the
/// `@escaping` apply closures can append without tripping mutable-capture diagnostics.
@MainActor
private final class CallRecorder {
    private(set) var ids: [UUID] = []
    func append(_ id: UUID) {
        ids.append(id)
    }
}

private func isConnecting(_ state: AccountService.ConnectionState?) -> Bool {
    if case .connecting = state { return true }
    return false
}

@MainActor
private struct TwoConnectedAccountsFixture {
    let accountService: AccountService
    let presenceService: PresenceService
    let aliceTransport: MockTransport
    let bobTransport: MockTransport
    let aliceID: UUID
    let bobID: UUID
    let aliceTask: Task<Void, any Error>
    let bobTask: Task<Void, any Error>

    func teardown() async {
        aliceTask.cancel()
        bobTask.cancel()
        await accountService.disconnect(accountID: aliceID)
        await accountService.disconnect(accountID: bobID)
    }
}

@MainActor
private func makeTwoConnectedAccounts() async throws -> TwoConnectedAccountsFixture {
    let store = MockPersistenceStore()
    let credentials = MockCredentialStore()
    let aliceTransport = MockTransport()
    let bobTransport = MockTransport()
    let factory = MockXMPPClientFactory(
        transportForAccount: { $0.jid.localPart == "alice" ? aliceTransport : bobTransport },
        modulesForAccount: { _ in [PresenceModule(), CapsModule()] }
    )
    let accountService = AccountService(store: store, credentialStore: credentials, clientFactory: factory)
    let presenceService = PresenceService()
    presenceService.setAccountService(accountService)

    let aliceID = try await accountService.createAccount(jidString: "alice@example.com", host: "example.com", port: 5222)
    let bobID = try await accountService.createAccount(jidString: "bob@example.com", host: "example.com", port: 5222)
    let (_, aliceTask) = try await driveMockConnect(accountService, accountID: aliceID, transport: aliceTransport, awaitInitialPresence: true)
    let (_, bobTask) = try await driveMockConnect(accountService, accountID: bobID, transport: bobTransport, awaitInitialPresence: true)

    return TwoConnectedAccountsFixture(
        accountService: accountService,
        presenceService: presenceService,
        aliceTransport: aliceTransport,
        bobTransport: bobTransport,
        aliceID: aliceID,
        bobID: bobID,
        aliceTask: aliceTask,
        bobTask: bobTask
    )
}

/// An `AccountService`/`PresenceService` pair with no connected accounts, for asserting the connect closures
/// the global apply path invokes without driving real handshakes.
@MainActor
private func makeUnconnectedService() -> (AccountService, PresenceService) {
    let store = MockPersistenceStore()
    let credentials = MockCredentialStore()
    let factory = MockXMPPClientFactory(transportForAccount: { _ in MockTransport() })
    let accountService = AccountService(store: store, credentialStore: credentials, clientFactory: factory)
    let presenceService = PresenceService()
    presenceService.setAccountService(accountService)
    return (accountService, presenceService)
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
