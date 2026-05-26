import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIProfileTests {
        @Test(arguments: ["plain", "json", "ansi"])
        @MainActor func `profile prints the own vCard across output formats`(format: String) async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                // Alice carries a pre-published vCard baseline (see `TestCredentials`), so `profile` emits a
                // non-empty rendering in every formatter; `--output` is pinned because piped stdout is non-TTY.
                let output = try await cli.run(["profile", "--output", format])
                #expect(output.exitCode == 0)
                #expect(!output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
