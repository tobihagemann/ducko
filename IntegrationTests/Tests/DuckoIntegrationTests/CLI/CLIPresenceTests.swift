import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIPresenceTests {
        @Test
        @MainActor func `ducko presence away echoes formatted presence locally`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                // `Presence.run` connects, broadcasts, then disconnects,
                // so peer-observed presence is unreachable from this
                // command. Only verify alice's own echoed presence:
                // `PlainFormatter.formatPresence` emits "<jid> is
                // <status>: <message>".
                let output = try await cli.run([
                    "presence", "away", "BRB", "--output", "plain"
                ])
                #expect(output.exitCode == 0)
                #expect(output.stdout.contains("BRB"))
                #expect(output.stdout.contains("away"))
            }
        }

        // Disabled: CLI `/roster` short-circuits with "No contacts in
        // roster." when the roster is empty, so alice's away presence is
        // not observable through bob's `/roster` output without mutual
        // subscription, which the CLI layer has no helper to seed. The
        // protocol-layer harness has `setUpBobSubscribedToAlice`; track
        // re-enabling in `.turbo/improvements.md`.
        @Test(.disabled("CLI /roster does not surface presence for non-roster peers; test premise requires mutual alice↔bob subscription which is not reliably seeded by this layer. See improvements backlog."))
        @MainActor func `REPL /status changes presence visible to a peer`() {}
    }
}
