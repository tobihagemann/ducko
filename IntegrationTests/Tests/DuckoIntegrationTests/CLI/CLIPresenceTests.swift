import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIPresenceTests {
        @Test(.enabled(if: CLIProcess.binaryExists, "DuckoCLI binary missing"))
        @MainActor func `ducko presence away echoes formatted presence locally`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                // `presence` connects, broadcasts, then disconnects (`DuckoCLI.swift:316-365`),
                // so peer-observed presence is unreachable from this command. Only verify
                // alice's own echoed presence: `PlainFormatter.formatPresence` emits
                // "<jid> is <status>: <message>" (`PlainFormatter.swift:57-62`).
                let output = try await cli.run([
                    "presence", "away", "BRB", "--output", "plain"
                ])
                #expect(output.exitCode == 0)
                #expect(output.stdout.contains("BRB"))
                #expect(output.stdout.contains("away"))
            }
        }

        // The CLI's `/roster` command short-circuits with "No contacts in
        // roster." when `rosterService.groups` is empty — even when alice's
        // away presence has reached bob's `presenceService.contactPresences`,
        // it is unreachable through bob's `/roster` output. Verifying this
        // flow end-to-end requires bob to have alice in his roster (mutual
        // subscription). The protocol-layer harness sets this up explicitly
        // (`Protocol/PresenceTests.swift:119` via
        // `setUpBobSubscribedToAlice`); the CLI layer has no equivalent
        // surface today. Track in `.turbo/improvements.md` until the CLI
        // exposes a way to seed mutual subscription per-test.
        @Test(.disabled("CLI /roster does not surface presence for non-roster peers; test premise requires mutual alice↔bob subscription which is not reliably seeded by this layer. See improvements backlog."))
        @MainActor func `REPL /status changes presence visible to a peer`() async throws {
            let aliceProfile = "inttest-alice-\(UUID().uuidString.prefix(8))"
            let bobProfile = "inttest-bob-\(UUID().uuidString.prefix(8))"

            try await CLIProcess.withProcess(profile: aliceProfile) { aliceCLI in
                try await CLIProcess.withProcess(profile: bobProfile) { bobCLI in
                    let alice = TestCredentials.alice
                    let bob = TestCredentials.bob

                    let aliceREPL = try await REPLSession.start(cli: aliceCLI, credentials: alice)
                    await aliceCLI.addCleanup { await aliceREPL.terminate() }

                    // The PTY makes `OutputFormat.defaultForTerminal` resolve to
                    // `.ansi`, which renders presence as colored `●`/`○` dots
                    // (`ANSIFormatter.swift:53-68`). We assert against the plain
                    // `[~]` marker (`PlainFormatter.swift:38-51`), so pin bob's
                    // REPL to plain output.
                    let bobREPL = try await REPLSession.start(
                        cli: bobCLI, credentials: bob, arguments: ["--output", "plain"]
                    )
                    await bobCLI.addCleanup { await bobREPL.terminate() }

                    try await aliceREPL.send("/status away BRB")

                    // Peer status MESSAGE text is not retained in
                    // `PresenceService.contactPresencesByAccount`
                    // (`PresenceService.swift:184-191` stores only the status enum), so
                    // bob's /roster surfaces the away indicator but not "BRB".
                    // Use the connect timeout (15s) — propagation through the
                    // server can lag behind the smaller event timeout under
                    // load, especially on the heels of two prior REPL spawns
                    // in this suite.
                    let deadline = ContinuousClock.now.advanced(by: TestTimeout.connect)
                    var seen = false
                    while ContinuousClock.now < deadline {
                        try await bobREPL.send("/roster")
                        try await Task.sleep(for: .milliseconds(500))
                        let snapshot = await bobREPL.snapshot()
                        if snapshot
                            .split(separator: "\n")
                            .contains(where: { $0.contains(alice.jid) && $0.contains("[~]") }) {
                            seen = true
                            break
                        }
                    }
                    if !seen {
                        // Surface bob's full /roster snapshot in the failure
                        // so a missing mutual subscription, an absent away
                        // marker, or an empty roster shows up immediately
                        // instead of as an opaque timeout.
                        let snapshot = await bobREPL.snapshot()
                        Issue.record("bob's /roster never showed alice as away. snapshot:\n\(snapshot)")
                        throw TestHarnessError.timeout
                    }
                }
            }
        }
    }
}
