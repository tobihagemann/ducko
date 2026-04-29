import DuckoCore
import DuckoXMPP
import Foundation
import Logging
import Testing

private let log = Logger(label: "im.ducko.integrationtests.reset")

/// One-shot live-server fixture hygiene suite. Skipped by default; runs only
/// when `DUCKO_RESET_FIXTURES=1` and the standard `IntegrationTests/.env.test`
/// credentials are configured.
///
/// Two server-side drift sources motivate this suite:
///
/// 1. PEP `urn:xmpp:omemo:2:devices` accumulates stale device IDs across
///    runs, and each obsolete device leaves a dangling
///    `urn:xmpp:omemo:2:bundles:<deviceID>` node behind. Once the list
///    crosses `OMEMOModule.pruneProbeCap` (64) the client cannot self-heal;
///    sends race ack overflow and dependent tests fail. Retracting the
///    devicelist and reconnecting causes `OMEMOModule.ensureOwnDeviceInList`
///    to publish a fresh singleton list containing only the live device ID.
///    Then a disco#items sweep deletes every other bundle node so the live
///    server matches the post-`purge-test-omemo.sql` shape (one devicelist
///    + one bundle per account).
///
/// 2. Roster baseline subscriptions can be lost (server retention edges,
///    per-test side effects). UI tests that expect Bob's contact row on
///    Alice fail silently. The reset reseeds `subscription=both` for the
///    canonical pairs (alice ↔ bob, alice ↔ carol, alice ↔ dave) and
///    persists the result by NOT registering removal cleanups.
///
/// Invoke with:
///
///     DUCKO_RESET_FIXTURES=1 swift test --package-path IntegrationTests \
///         --filter ResetTestServerState
extension DuckoIntegrationTests {
    struct ResetTestServerState {
        @Test(.enabled(
            if: ProcessInfo.processInfo.environment["DUCKO_RESET_FIXTURES"] == "1"
                && TestCredentials.isAvailable
                && TestCredentials.isDaveAvailable,
            "Set DUCKO_RESET_FIXTURES=1 and configure all four DUCKO_TEST_*_{JID,PASSWORD} pairs"
        ))
        @MainActor func `reset OMEMO devicelists and reseed roster baseline`() async throws {
            let accounts: [TestCredentials.Credential] = [
                TestCredentials.alice,
                TestCredentials.bob,
                TestCredentials.carol,
                TestCredentials.dave
            ]

            for credential in accounts {
                try await Self.resetOMEMODeviceList(for: credential)
            }

            try await Self.reseedRosterBaseline(accounts: accounts)
        }

        // MARK: - OMEMO Devicelist Reset

        /// Retracts `urn:xmpp:omemo:2:devices` for `credential`, then
        /// disconnects and reconnects so `OMEMOModule.ensureOwnDeviceInList`
        /// republishes a singleton list containing only the live device ID.
        /// Verifies the post-reconnect list is a singleton, then deletes
        /// every `urn:xmpp:omemo:2:bundles:<deviceID>` node whose deviceID
        /// is not the live one — matching `purge-test-omemo.sql`.
        @MainActor
        private static func resetOMEMODeviceList(for credential: TestCredentials.Credential) async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [credential.label: credential])

                let pep = try await harness.module(PEPModule.self, for: credential.label)
                do {
                    try await pep.retractItem(node: XMPPNamespaces.omemoDevices, itemID: "current")
                    log.info("Retracted OMEMO devicelist for \(credential.label)")
                } catch {
                    // First-time accounts have no node yet; treat as success.
                    log.debug("OMEMO devicelist retract for \(credential.label) returned \(error) — continuing")
                }

                let account = try #require(harness.accounts[credential.label])
                await harness.environment.accountService.disconnect(accountID: account.accountID)
                try await harness.environment.accountService.connect(
                    accountID: account.accountID,
                    password: credential.password
                )

                _ = try await account.waitForEvent(matching: { event in
                    if case .rosterLoaded = event { return true }
                    return false
                }, timeout: TestTimeout.connect)

                // Post-condition: the freshly-published devicelist must be a
                // singleton — exactly the live device ID. Catches a regression
                // where retract+republish leaves prior accumulation in place.
                // The OMEMO devicelist payload root is `<list xmlns="urn:xmpp:omemo:2">`
                // with one `<device id="…"/>` child per device, so count children
                // directly (matches `OMEMOModule.parseDeviceList`'s shape).
                // Use `try #require` rather than `#expect`: a non-singleton or
                // missing-id state would leave `liveDeviceID` nil and cause
                // the bundle sweep below to delete the just-published live
                // bundle along with the stale ones.
                let pepAfter = try await harness.module(PEPModule.self, for: credential.label)
                let items = try await pepAfter.retrieveItems(node: XMPPNamespaces.omemoDevices, from: nil)
                let devices = items.first?.payload.children(named: "device") ?? []
                try #require(devices.count == 1, "Expected singleton devicelist for \(credential.label), got \(devices.count) entries")
                let liveDeviceID = try #require(devices.first?.attribute("id"), "Singleton devicelist for \(credential.label) is missing the `id` attribute")

                try await Self.deleteStaleBundleNodes(
                    for: credential,
                    keeping: liveDeviceID,
                    on: harness
                )
            }
        }

        /// Sweeps every `urn:xmpp:omemo:2:bundles:<deviceID>` PEP node owned
        /// by `credential` and deletes the ones whose deviceID does not match
        /// `liveDeviceID`. The post-reconnect bundle for the live device is
        /// preserved so OMEMO can resume immediately after the reset. Mirrors
        /// the `prosodyarchive` half of `purge-test-omemo.sql`. Asserts no
        /// stale bundle nodes remain after the sweep.
        @MainActor
        private static func deleteStaleBundleNodes(
            for credential: TestCredentials.Credential,
            keeping liveDeviceID: String,
            on harness: TestHarness
        ) async throws {
            let disco = try await harness.module(ServiceDiscoveryModule.self, for: credential.label)
            let pep = try await harness.module(PEPModule.self, for: credential.label)

            let liveBundleNode = "\(OMEMOModule.bundleNodePrefix)\(liveDeviceID)"
            let bareJID = try harness.jid(for: credential)

            let stale = try await Self.staleBundleNodes(
                in: disco.queryItems(for: .bare(bareJID)),
                ownedBy: bareJID,
                keeping: liveBundleNode
            )

            var deleted = 0
            for node in stale {
                do {
                    try await pep.deleteNode(node: node)
                    deleted += 1
                } catch {
                    // Best-effort per node: a server-side race or an
                    // already-gone node shouldn't abort the loop. Real
                    // failures (forbidden, feature-not-implemented, repeated
                    // timeouts) are caught by the postcondition re-query
                    // below — they would leave stale nodes visible.
                    log.debug("Bundle node delete \(node) for \(credential.label) returned \(error) — continuing")
                }
            }
            log.info("Deleted \(deleted) stale OMEMO bundle node(s) for \(credential.label)")

            let remaining = try await Self.staleBundleNodes(
                in: disco.queryItems(for: .bare(bareJID)),
                ownedBy: bareJID,
                keeping: liveBundleNode
            )
            #expect(remaining.isEmpty, "Stale OMEMO bundle nodes still present for \(credential.label) after sweep: \(remaining)")
        }

        /// Filters disco#items results to the OMEMO bundle node names
        /// (`urn:xmpp:omemo:2:bundles:<deviceID>`) owned by `bareJID` that
        /// are not the live bundle. Shared by the sweep loop and its
        /// postcondition re-query so the two definitions of "stale"
        /// cannot drift.
        static func staleBundleNodes(
            in items: [ServiceDiscoveryModule.Item],
            ownedBy bareJID: BareJID,
            keeping liveBundleNode: String
        ) -> [String] {
            items.compactMap { item in
                guard item.jid.bareJID == bareJID,
                      let node = item.node,
                      node.hasPrefix(OMEMOModule.bundleNodePrefix),
                      node != liveBundleNode else { return nil }
                return node
            }
        }

        // MARK: - Roster Baseline Reseed

        /// Seeds `subscription='both'` for the canonical pairs (alice ↔ bob,
        /// alice ↔ carol, alice ↔ dave). Subscriptions persist after teardown
        /// because no removal cleanup is registered.
        @MainActor
        private static func reseedRosterBaseline(accounts: [TestCredentials.Credential]) async throws {
            try await TestHarness.withHarness { harness in
                let labelled = Dictionary(uniqueKeysWithValues: accounts.map { ($0.label, $0) })
                try await harness.setUp(accounts: labelled)

                for peer in [TestCredentials.bob, TestCredentials.carol, TestCredentials.dave] {
                    try await Self.setUpMutualSubscription(
                        first: TestCredentials.alice,
                        second: peer,
                        on: harness
                    )
                }
            }
        }

        /// One side of the subscription dance. Bundles together the four
        /// pieces (account, roster module, label, JID) keyed by credential
        /// so the helper signature stays under SwiftLint's parameter cap.
        private struct SubscriptionEndpoint {
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
        }

        /// Runs a bidirectional subscription dance so both endpoints end up
        /// with `subscription='both'` for each other. Mirrors
        /// `setUpBobSubscribedToAlice` (PresenceTests.swift) but runs the
        /// dance in both directions and registers no removal cleanup, so the
        /// seeded subscriptions persist on the live server.
        @MainActor
        private static func setUpMutualSubscription(
            first: TestCredentials.Credential,
            second: TestCredentials.Credential,
            on harness: TestHarness
        ) async throws {
            let firstEndpoint = try await SubscriptionEndpoint.resolve(credential: first, on: harness)
            let secondEndpoint = try await SubscriptionEndpoint.resolve(credential: second, on: harness)

            try await Self.subscribeAndApprove(requester: secondEndpoint, approver: firstEndpoint)
            try await Self.subscribeAndApprove(requester: firstEndpoint, approver: secondEndpoint)

            log.info("Reseeded subscription=both between \(first.label) and \(second.label)")
        }

        /// Tolerant subscribe-and-approve: if the requester already has the
        /// approver in roster with `subscription='both'`, the server skips
        /// the subscription-request push and `waitForEvent` throws
        /// `.timeout`. Catching only that case keeps the suite idempotent
        /// across reruns without masking other harness failures (stream
        /// closure, unexpected event-stream errors).
        @MainActor
        private static func subscribeAndApprove(
            requester: SubscriptionEndpoint,
            approver: SubscriptionEndpoint
        ) async throws {
            try await requester.roster.subscribe(to: approver.jid)

            let receivedRequest: Bool
            do {
                _ = try await approver.account.waitForEvent(
                    matching: { event in
                        if case let .presenceSubscriptionRequest(from) = event, from == requester.jid {
                            return true
                        }
                        return false
                    },
                    timeout: .seconds(3)
                )
                receivedRequest = true
            } catch TestHarnessError.timeout {
                receivedRequest = false
            }

            guard receivedRequest else {
                log.debug("Subscription \(requester.credential.label) → \(approver.credential.label) already in place; skipping approve")
                return
            }

            try await approver.roster.approveSubscription(from: requester.jid)

            // Tolerate timeout on the approval push: the subscription is
            // committed server-side once `approveSubscription` returns,
            // even if the round-trip notification doesn't reach the
            // requester within the wait window. Other errors propagate.
            do {
                _ = try await requester.account.waitForEvent(matching: { event in
                    if case let .presenceSubscriptionApproved(from) = event, from == approver.jid {
                        return true
                    }
                    return false
                }, timeout: .seconds(3))
            } catch TestHarnessError.timeout {
                // Subscription is committed; missing push is benign here.
            }
        }
    }
}
