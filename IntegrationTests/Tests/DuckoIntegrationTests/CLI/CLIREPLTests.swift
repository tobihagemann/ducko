import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIREPLTests {
        @Test(.enabled(if: CLIProcess.binaryExists, "DuckoCLI binary missing"))
        @MainActor func `REPL starts and prints the connection banner`() async throws {
            try await CLIProcess.withProcess { aliceCLI in
                let alice = TestCredentials.alice
                let session = try await REPLSession.start(cli: aliceCLI, credentials: alice)
                await aliceCLI.addCleanup { await session.terminate() }

                // `REPLSession.start` already waits for the banner; assert the prefix
                // that `DuckoCLI.swift:151` prints on a successful connect.
                let snapshot = await session.snapshot()
                #expect(snapshot.contains("Connected. Type 'help' for commands"))
            }
        }

        @Test(.enabled(if: CLIProcess.binaryExists, "DuckoCLI binary missing"))
        @MainActor func `REPL send and receive cycle works`() async throws {
            let aliceProfile = "inttest-alice-\(UUID().uuidString.prefix(8))"
            let bobProfile = "inttest-bob-\(UUID().uuidString.prefix(8))"

            try await CLIProcess.withProcess(profile: aliceProfile) { aliceCLI in
                try await CLIProcess.withProcess(profile: bobProfile) { bobCLI in
                    let alice = TestCredentials.alice
                    let bob = TestCredentials.bob

                    let aliceREPL = try await REPLSession.start(cli: aliceCLI, credentials: alice)
                    await aliceCLI.addCleanup { await aliceREPL.terminate() }

                    let bobREPL = try await REPLSession.start(cli: bobCLI, credentials: bob)
                    await bobCLI.addCleanup { await bobREPL.terminate() }

                    let ping = "ping-\(UUID().uuidString.prefix(8))"
                    let pong = "pong-\(UUID().uuidString.prefix(8))"

                    try await aliceREPL.send("send \(bob.jid) \(ping)")
                    _ = try await bobREPL.waitForOutput(containing: ping, timeout: TestTimeout.replOutput)

                    try await bobREPL.send("send \(alice.jid) \(pong)")
                    _ = try await aliceREPL.waitForOutput(containing: pong, timeout: TestTimeout.replOutput)
                }
            }
        }

        @Test(.enabled(if: CLIProcess.binaryExists, "DuckoCLI binary missing"))
        @MainActor func `REPL /roster /status /history /who produce output`() async throws {
            try await CLIProcess.withProcess { aliceCLI in
                let alice = TestCredentials.alice
                let bob = TestCredentials.bob

                // The PTY makes `OutputFormat.defaultForTerminal` resolve to
                // `.ansi`, but the assertions below pin Plain markers like
                // `[+]`/`[~]`/`[-]` (`PlainFormatter.swift:38-51`) and
                // `--- group ---` headers. ANSIFormatter renders presence as
                // colored `●`/`○` dots (`ANSIFormatter.swift:53-68`), so pin
                // the REPL to plain output.
                let session = try await REPLSession.start(
                    cli: aliceCLI, credentials: alice, arguments: ["--output", "plain"]
                )
                await aliceCLI.addCleanup { await session.terminate() }

                // `/roster`: prints either a group header
                // ("--- <group name> (<count>) ---", `PlainFormatter.swift:53-55`) or
                // "No contacts in roster." when the roster is empty
                // (`DuckoCLI.swift:2401-2404`). Either marker proves the command ran.
                try await session.send("/roster")
                _ = try await session.waitForOutput(
                    containingAnyOf: ["---", "No contacts in roster."],
                    timeout: TestTimeout.replOutput
                )

                // `/status` (no args) echoes alice's own presence via
                // `formatPresence` ("<jid> is <status>", `PlainFormatter.swift:57-62`).
                try await session.send("/status")
                _ = try await session.waitForOutput(
                    containing: "\(alice.jid) is ",
                    timeout: TestTimeout.replOutput
                )

                // `/history <jid>` rejects a bare invocation with a usage hint
                // (`DuckoCLI.swift:2491-2494`). Pass bob's JID so the handler proceeds
                // and prints either a row or "No messages found."
                // (`HistoryHelpers.swift:51`). On a fresh inttest profile no transcript
                // exists yet, so we pin the empty-state string.
                try await session.send("/history \(bob.jid)")
                _ = try await session.waitForOutput(
                    containing: "No messages found.",
                    timeout: TestTimeout.replOutput
                )

                // `/who` prints presence-indicator lines for online contacts or
                // "No contacts online." when nobody is online (`DuckoCLI.swift:2451-2454`,
                // `PlainFormatter.swift:38-51`). Capture a cursor before sending
                // so the assertion only matches output produced by `/who`, not
                // `[+]`/`[~]`/`[-]` markers already in the buffer from `/roster`.
                let cursorBeforeWho = await session.cursor()
                try await session.send("/who")
                _ = try await session.waitForOutput(
                    containingAnyOf: ["No contacts online.", "[+]", "[~]", "[-]"],
                    after: cursorBeforeWho,
                    timeout: TestTimeout.replOutput
                )
            }
        }
    }
}
