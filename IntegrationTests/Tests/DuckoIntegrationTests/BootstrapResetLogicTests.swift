import Foundation
import Testing

/// Pure-logic tests for `TestHarness.runBootstrapResetIfNeeded`. Drives the
/// gate with injected probe and reset closures so the threshold-check
/// branches can be exercised without touching a live server. Lives inside
/// `IntegrationTests` because the function under test is package-internal
/// to the integration target.
///
/// These tests are gated on `TestCredentials.isAvailable` only — they don't
/// fire reset against the live server because they hand the gate fake
/// probes and fake reset closures.
extension DuckoIntegrationTests {
    @Suite(.enabled(if: TestCredentials.isAvailable, "XMPP test credentials not set"))
    struct BootstrapResetLogicTests {
        @Test
        @MainActor
        func `all-under-threshold counts do not trigger reset`() async throws {
            let resetCalled = ResetTracker()
            try await TestHarness.runBootstrapResetIfNeeded(
                probe: { _ in 1 },
                reset: { credential in await resetCalled.record(credential.label) }
            )
            #expect(await resetCalled.calls.isEmpty)
        }

        @Test
        @MainActor
        func `one-over-threshold triggers reset for every available credential`() async throws {
            let resetCalled = ResetTracker()
            try await TestHarness.runBootstrapResetIfNeeded(
                probe: { credential in
                    credential.label == "alice" ? TestHarness.autoResetDevicelistThreshold + 1 : 1
                },
                reset: { credential in await resetCalled.record(credential.label) }
            )
            // Reset fires for every credential the bootstrap considered —
            // alice/bob/carol always; dave only if its credentials are set.
            let expected: Set<String> = if TestCredentials.isDaveAvailable {
                ["alice", "bob", "carol", "dave"]
            } else {
                ["alice", "bob", "carol"]
            }
            #expect(await Set(resetCalled.calls) == expected)
        }

        @Test
        @MainActor
        func `probe timeout bails without invoking reset`() async throws {
            let resetCalled = ResetTracker()
            try await TestHarness.runBootstrapResetIfNeeded(
                probe: { credential in
                    // Simulate the timeout-or-failure path by returning nil
                    // for the first credential (alphabetically, alice).
                    credential.label == "alice" ? nil : (TestHarness.autoResetDevicelistThreshold + 1)
                },
                reset: { credential in await resetCalled.record(credential.label) }
            )
            #expect(await resetCalled.calls.isEmpty)
        }

        @Test
        @MainActor
        func `zero counts do not trigger reset`() async throws {
            let resetCalled = ResetTracker()
            try await TestHarness.runBootstrapResetIfNeeded(
                probe: { _ in 0 },
                reset: { credential in await resetCalled.record(credential.label) }
            )
            #expect(await resetCalled.calls.isEmpty)
        }
    }
}

/// Records reset-closure invocations for the bootstrap logic tests.
/// Isolated as an `actor` so a future migration to parallel test execution
/// (today gated by `.serialized` on the root suite) keeps the recorder
/// concurrency-safe.
actor ResetTracker {
    private(set) var calls: [String] = []

    func record(_ label: String) {
        calls.append(label)
    }
}
