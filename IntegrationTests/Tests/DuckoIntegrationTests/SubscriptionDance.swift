import DuckoCore
import DuckoXMPP
import Foundation
import Logging
import Testing

private let log = Logger(label: "im.ducko.integrationtests.subscription")

struct SubscriptionEndpoint {
    let credential: TestCredentials.Credential
    let account: ConnectedAccount
    let roster: RosterModule
    let jid: BareJID

    @MainActor
    static func resolve(
        credential: TestCredentials.Credential,
        on harness: TestHarness
    ) async throws -> SubscriptionEndpoint {
        try await SubscriptionEndpoint(
            credential: credential,
            account: #require(harness.accounts[credential.label]),
            roster: harness.module(RosterModule.self, for: credential.label),
            jid: harness.jid(for: credential)
        )
    }

    var asApprover: SubscriptionApprover {
        SubscriptionApprover(label: credential.label, jid: jid)
    }

    /// Waits for `.presenceSubscriptionApproved(from: approver)`. Shared so
    /// the predicate and timeout source live in one place.
    @MainActor
    func waitForApproval(from approver: BareJID) async throws {
        _ = try await account.waitForEvent(matching: { event in
            if case let .presenceSubscriptionApproved(from) = event, from == approver {
                return true
            }
            return false
        }, timeout: TestTimeout.event)
    }
}

/// Minimal identity for the approver side. The approver may not run in the
/// in-process harness (e.g. when alice runs as a CLI process), so only
/// `jid` and `label` are required.
struct SubscriptionApprover {
    let label: String
    let jid: BareJID
}

enum SubscriptionDance {
    /// Tolerant subscribe-and-approve: catches only `TestHarnessError.timeout`
    /// on the request wait so an existing `subscription='both'` baseline
    /// short-circuits idempotently, while real harness failures (stream
    /// closure, unexpected event-stream errors) propagate.
    ///
    /// `onMutationDetected` fires once `waitForRequest` has confirmed the
    /// server accepted the subscribe and BEFORE `approve` runs. Callers
    /// register cleanup there so a failure during `approve` or the fatal
    /// `presenceSubscriptionApproved` wait still triggers teardown of the
    /// just-mutated roster state.
    /// Convenience overload that derives canonical `subscribe:` and
    /// `awaitApproval:` closures from typed endpoints; callers only differ
    /// in `waitForRequest:` and `approve:`. Deterministic tests use the
    /// closure-injected base form directly.
    @MainActor
    static func subscribeAndApprove(
        requester: SubscriptionEndpoint,
        approver: SubscriptionApprover,
        waitForRequest: () async throws -> Void,
        approve: () async throws -> Void,
        onMutationDetected: @MainActor () async throws -> Void = {}
    ) async throws {
        try await subscribeAndApprove(
            requesterLabel: requester.credential.label,
            approverLabel: approver.label,
            subscribe: { try await requester.roster.subscribe(to: approver.jid) },
            waitForRequest: waitForRequest,
            approve: approve,
            awaitApproval: { try await requester.waitForApproval(from: approver.jid) },
            onMutationDetected: onMutationDetected
        )
    }

    @MainActor
    // swiftlint:disable:next function_parameter_count
    static func subscribeAndApprove(
        requesterLabel: String,
        approverLabel: String,
        subscribe: @MainActor () async throws -> Void,
        waitForRequest: () async throws -> Void,
        approve: () async throws -> Void,
        awaitApproval: @MainActor () async throws -> Void,
        onMutationDetected: @MainActor () async throws -> Void = {}
    ) async throws {
        try await subscribe()

        let receivedRequest: Bool
        do {
            try await waitForRequest()
            receivedRequest = true
        } catch TestHarnessError.timeout {
            receivedRequest = false
        }

        guard receivedRequest else {
            log.debug("Subscription \(requesterLabel) → \(approverLabel) already in place; skipping approve")
            return
        }

        try await onMutationDetected()
        try await approve()

        // Fatal: we sent a real `<presence type="subscribed">`, so a missing
        // inbound `presenceSubscriptionApproved` is a regression in event
        // delivery, not a benign network blip.
        try await awaitApproval()
    }

    /// Asserts neither side has the other in their live-server roster.
    /// Reloads both rosters from the server before reading so a stale
    /// local cache cannot mask drift. Used as a precondition guard in
    /// `RosterTests` and as a postcondition for
    /// `ResetTestServerState.scrubSubscription`.
    @MainActor
    static func assertNoSubscription(
        harness: TestHarness,
        first: TestCredentials.Credential,
        second: TestCredentials.Credential
    ) async throws {
        let firstEndpoint = try await SubscriptionEndpoint.resolve(credential: first, on: harness)
        let secondEndpoint = try await SubscriptionEndpoint.resolve(credential: second, on: harness)
        try await harness.environment.rosterService.loadContacts(for: firstEndpoint.account.accountID)
        try await harness.environment.rosterService.loadContacts(for: secondEndpoint.account.accountID)
        let contacts = harness.environment.rosterService.groups.flatMap(\.contacts)
        let firstHasSecond = contacts.contains {
            $0.accountID == firstEndpoint.account.accountID && $0.jid == secondEndpoint.jid
        }
        let secondHasFirst = contacts.contains {
            $0.accountID == secondEndpoint.account.accountID && $0.jid == firstEndpoint.jid
        }
        try #require(!firstHasSecond, "\(second.label) must not be on \(first.label)'s roster")
        try #require(!secondHasFirst, "\(first.label) must not be on \(second.label)'s roster")
    }

    /// In-harness symmetric variant: both sides have full
    /// `SubscriptionEndpoint`s, so the request-wait fires on the approver's
    /// `XMPPEvent` stream and the approve action calls
    /// `RosterModule.approveSubscription` directly. Used by both
    /// `ResetTestServerState.setUpMutualSubscription` and
    /// `PresenceTests.setUpBobSubscribedToAlice`.
    @MainActor
    static func subscribeAndApproveInHarness(
        requester: SubscriptionEndpoint,
        approver: SubscriptionEndpoint,
        onMutationDetected: @MainActor () async throws -> Void = {}
    ) async throws {
        try await subscribeAndApprove(
            requester: requester,
            approver: approver.asApprover,
            waitForRequest: {
                _ = try await approver.account.waitForEvent(matching: { event in
                    if case let .presenceSubscriptionRequest(from) = event, from == requester.jid {
                        return true
                    }
                    return false
                }, timeout: TestTimeout.subscriptionRequestProbe)
            },
            approve: {
                try await approver.roster.approveSubscription(from: requester.jid)
            },
            onMutationDetected: onMutationDetected
        )
    }
}
