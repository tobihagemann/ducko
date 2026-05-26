import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIServerInfoTests {
        @Test(arguments: ["plain", "json", "ansi"])
        @MainActor func `server-info runs across output formats`(format: String) async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                // XEP-0157 contact addresses are server-config-dependent, so assert the disco round-trip and
                // render complete cleanly across formats; `--output` is pinned because piped stdout is non-TTY.
                let output = try await cli.run(["server-info", "--output", format])
                #expect(output.exitCode == 0)
            }
        }
    }
}
