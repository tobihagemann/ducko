import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIHistoryTests {
        @Test
        @MainActor func `ducko history reports empty state on a fresh profile`() async throws {
            try await CLIProcess.withProcess { cli in
                // The standalone `History` subcommand has its own argument
                // parsing and process lifecycle distinct from the REPL
                // `/history` handler (covered by `CLIREPLTests`). A fresh
                // inttest profile has no transcript, so `printHistory`
                // emits "No messages found." and the process exits 0
                // without contacting the server (`--server` not passed).
                let alice = TestCredentials.alice
                let bob = TestCredentials.bob
                try await cli.seedAccount(alice)

                let output = try await cli.run([
                    "history", bob.jid, "--output", "plain"
                ])
                #expect(output.exitCode == 0)
                #expect(output.stdout.contains("No messages found."))
            }
        }
    }
}
