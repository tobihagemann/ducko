import DuckoXMPP
import Foundation
import Testing

/// Pins the JID-filter predicate inside
/// `SubscriptionEndpoint.waitForApproval(from:)`. A regression that removed
/// the filter (e.g. `from == _`) would still pass any live test where the
/// happy-path approval eventually arrives. Top-level `enum` to opt out of
/// the parent suite's `.enabled(if:)` credentials trait.
enum SubscriptionEndpointTests {
    @MainActor
    struct WaitForApproval {
        @Test
        func `approval from matching JID resolves the wait`() async throws {
            let router = EventRouter()
            let accountID = UUID()
            let account = ConnectedAccount(accountID: accountID, router: router)
            let endpoint = Self.endpoint(account: account)
            let approver = try #require(BareJID.parse("dave@example.test"))

            let waitTask = Task { @MainActor in
                try await endpoint.waitForApproval(from: approver)
            }
            try? await Task.sleep(for: .milliseconds(20))
            router.dispatch(.presenceSubscriptionApproved(from: approver), accountID: accountID)
            try await waitTask.value
        }

        @Test
        func `approval from a different JID is ignored until the matching one arrives`() async throws {
            let router = EventRouter()
            let accountID = UUID()
            let account = ConnectedAccount(accountID: accountID, router: router)
            let endpoint = Self.endpoint(account: account)
            let expected = try #require(BareJID.parse("dave@example.test"))
            let other = try #require(BareJID.parse("eve@example.test"))

            let waitTask = Task { @MainActor in
                try await endpoint.waitForApproval(from: expected)
            }
            try? await Task.sleep(for: .milliseconds(20))
            // Decoy event from a different JID — must not resolve the wait.
            router.dispatch(.presenceSubscriptionApproved(from: other), accountID: accountID)
            try? await Task.sleep(for: .milliseconds(20))
            router.dispatch(.presenceSubscriptionApproved(from: expected), accountID: accountID)
            try await waitTask.value
        }

        @Test
        func `non-approval event for the same JID is ignored until approval arrives`() async throws {
            let router = EventRouter()
            let accountID = UUID()
            let account = ConnectedAccount(accountID: accountID, router: router)
            let endpoint = Self.endpoint(account: account)
            let approver = try #require(BareJID.parse("dave@example.test"))

            let waitTask = Task { @MainActor in
                try await endpoint.waitForApproval(from: approver)
            }
            try? await Task.sleep(for: .milliseconds(20))
            // Subscription REQUEST is the inbound counterpart, NOT approval.
            router.dispatch(.presenceSubscriptionRequest(from: approver), accountID: accountID)
            try? await Task.sleep(for: .milliseconds(20))
            router.dispatch(.presenceSubscriptionApproved(from: approver), accountID: accountID)
            try await waitTask.value
        }

        private static func endpoint(account: ConnectedAccount) -> SubscriptionEndpoint {
            SubscriptionEndpoint(
                credential: TestCredentials.Credential(jid: "alice@example.test", password: "", label: "alice"),
                account: account,
                roster: RosterModule(),
                jid: BareJID.parse("alice@example.test")!
            )
        }
    }
}
