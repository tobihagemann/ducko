import Foundation
import Testing

/// Live-server probe-path test for `TestHarness.runBootstrapResetIfNeeded`.
/// Exercises the real PEP fetch against alice's account on the test server.
/// Asserts the probe completes within the configured budget and (on a
/// clean baseline) returns a count below the auto-reset threshold so the
/// reset path does NOT fire as a side effect of running this test.
///
/// Gated on the standard credential availability gate so CI without
/// secrets remains buildable.
extension DuckoIntegrationTests {
    @Suite(.enabled(if: TestCredentials.isAvailable, "XMPP test credentials not set"))
    struct BootstrapResetTests {
        @Test
        @MainActor
        func `probe completes within budget on clean baseline`() async throws {
            let count = await TestHarness.probeOMEMODevicelistCount(for: TestCredentials.alice)
            let observed = try #require(count)
            #expect(observed <= TestHarness.autoResetDevicelistThreshold)
        }
    }
}
