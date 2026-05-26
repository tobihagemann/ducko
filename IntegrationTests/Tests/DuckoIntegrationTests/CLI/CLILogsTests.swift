import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLILogsTests {
        @Test
        @MainActor func `logs show prints recent log output`() async throws {
            try await CLIProcess.withProcess { cli in
                // `ducko logs` is local-only (no connect, no `--output`): it tails the profile-scoped log
                // file, or prints "(no log file found)" when none exists yet — either way non-empty stdout.
                let output = try await cli.run(["logs"])
                #expect(output.exitCode == 0)
                #expect(!output.stdout.isEmpty)
            }
        }
    }
}
