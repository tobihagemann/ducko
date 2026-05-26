import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIProcessTests {
        /// Pinning the failure path of `withProcessPair`: a thrown sentinel
        /// from `body` must rethrow untouched, and registered cleanups on
        /// both processes must still run. The pair's outer ordering is bob
        /// then alice (matching the helper's inlined teardown), and within
        /// each CLI cleanups run LIFO.
        @Test
        func `withProcessPair runs cleanups on both CLIs and rethrows on body failure`() async throws {
            struct Sentinel: Error, Equatable {}
            let recorder = TeardownRecorder()

            await #expect(throws: Sentinel.self) {
                try await CLIProcess.withProcessPair { aliceCLI, bobCLI in
                    await aliceCLI.addCleanup { await recorder.record("alice") }
                    await bobCLI.addCleanup { await recorder.record("bob") }
                    throw Sentinel()
                }
            }

            let order = await recorder.order
            #expect(order == ["bob", "alice"])
        }

        /// Pins `CLIProcess.run`'s timeout path: a command that outlives the deadline must trip the
        /// SIGTERM→SIGKILL escalation (`waitForProcessExit`/`killProcess`) and throw `TestHarnessError.timeout`,
        /// after which the helper still runs a fresh invocation. Uses a short explicit `timeout:` against a
        /// known-slow live connect rather than racing `Task.sleep`.
        @Test
        func `run timeout escalates to kill and a later invocation still works`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                // `roster list` performs a full live connect + roster sync (seconds); a sub-second timeout
                // reliably trips the escalation path.
                await #expect(throws: TestHarnessError.self) {
                    _ = try await cli.run(["roster", "list"], timeout: .milliseconds(200))
                }

                // The runner recovered from the kill: a fast, local-only invocation still succeeds.
                let listed = try await cli.run(["account", "list"])
                #expect(listed.exitCode == 0)
            }
        }

        /// Pins `REPLSession.terminate`'s PTY teardown: terminating mid-output must drain the reader and exit
        /// without hanging, and a fresh `REPLSession.start` must still spawn cleanly afterward.
        @Test
        func `REPL terminate drains cleanly mid-output and a fresh session starts after`() async throws {
            try await CLIProcess.withProcessPair { aliceCLI, bobCLI in
                let alice = TestCredentials.alice
                let bob = TestCredentials.bob

                let firstREPL = try await REPLSession.start(cli: aliceCLI, credentials: alice)
                // Issue a command that produces output, then tear down without waiting for it to settle —
                // terminate() must drain the reader and exit even mid-stream.
                try await firstREPL.send("/roster")
                await firstREPL.terminate()

                // A fresh REPL session spawns cleanly afterward (start() internally awaits the banner, so
                // reaching the cleanup registration proves the spawn + PTY setup succeeded).
                let secondREPL = try await REPLSession.start(cli: bobCLI, credentials: bob)
                await bobCLI.addCleanup { await secondREPL.terminate() }
            }
        }
    }
}

private actor TeardownRecorder {
    private(set) var order: [String] = []

    func record(_ tag: String) {
        order.append(tag)
    }
}
