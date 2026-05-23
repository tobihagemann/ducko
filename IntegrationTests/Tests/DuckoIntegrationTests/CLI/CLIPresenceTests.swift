import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIPresenceTests {
        // MARK: - Shared Helper

        /// Wires `SubscriptionDance.subscribeAndApprove` to Alice's REPL
        /// surface (stdout for the request observation, `/approve` for the
        /// approve action). Extracted because inlining pushes the test body
        /// past SwiftLint's `function_body_length` cap.
        @MainActor
        private static func subscribeViaREPL(
            requester: SubscriptionEndpoint,
            approver: SubscriptionApprover,
            aliceREPL: REPLSession,
            onMutationDetected: @MainActor () async throws -> Void
        ) async throws {
            try await SubscriptionDance.subscribeAndApprove(
                requester: requester,
                approver: approver,
                waitForRequest: {
                    _ = try await aliceREPL.waitForOutput(
                        containing: "Subscription request from \(requester.jid)",
                        timeout: TestTimeout.subscriptionRequestProbe
                    )
                },
                approve: {
                    try await aliceREPL.send("/approve \(requester.jid)")
                },
                onMutationDetected: onMutationDetected
            )
        }

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

        @Test
        @MainActor func `REPL /status changes presence visible to a peer`() async throws {
            // Hybrid harness: bob runs in-process so the harness can drive
            // RosterModule directly and observe XMPPEvent streams; alice runs
            // in a child CLI process so `/status` exercises the actual REPL
            // surface end-to-end. Mirrors the protocol-layer
            // `setUpBobSubscribedToAlice` shape from `PresenceTests.swift`
            // but substitutes `REPLSession` for alice's side.
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["bob": TestCredentials.bob])

                // Hoist every MainActor-isolated read out of the sending
                // `CLIProcess.withProcess` closure — captured values can be
                // touched async-free inside, but `harness.accounts` /
                // `harness.jid` / `harness.module` cannot be called there.
                let bob = try #require(harness.accounts["bob"])
                let aliceJID = try harness.jid(for: TestCredentials.alice)
                let bobJID = try harness.jid(for: TestCredentials.bob)
                let bobEndpoint = try await SubscriptionEndpoint.resolve(credential: TestCredentials.bob, on: harness)

                try await CLIProcess.withProcess { aliceCLI in
                    let aliceREPL = try await REPLSession.start(cli: aliceCLI, credentials: TestCredentials.alice)
                    await aliceCLI.addCleanup { await aliceREPL.terminate() }

                    // Conditional cleanup registered via `onMutationDetected`
                    // so a failure during `/approve` or the fatal approval-push
                    // wait still tears down the just-mutated subscription. See
                    // `SubscriptionDance.subscribeAndApprove`.
                    try await Self.subscribeViaREPL(
                        requester: bobEndpoint,
                        approver: SubscriptionApprover(label: TestCredentials.alice.label, jid: aliceJID),
                        aliceREPL: aliceREPL,
                        onMutationDetected: {
                            harness.addCleanup { try? await bobEndpoint.roster.removeContact(jid: aliceJID) }
                            await aliceCLI.addCleanup {
                                try? await aliceREPL.send("/remove \(bobJID)")
                            }
                        }
                    )

                    // Routing-confirmation barrier: §3.1.5/§3.1.6 leave alice's
                    // server still pushing roster + current presence after the
                    // approval, so the assertion below could race that flow and
                    // be silently dropped. Drive a unique sentinel through the
                    // live path and wait for bob to observe it before changing
                    // alice's `/status`. Mirrors the warm-up barrier inside
                    // `setUpBobSubscribedToAlice` in PresenceTests.
                    let warmup = "warmup-\(UUID().uuidString.prefix(8))"
                    try await aliceREPL.send("/status available \(warmup)")
                    _ = try await bob.waitForEvent { event in
                        if case let .presenceUpdated(from: _, presence) = event,
                           presence.status == warmup,
                           presence.presenceType == nil {
                            return true
                        }
                        return false
                    }

                    // Drive the asserting `/status` change through alice's REPL.
                    try await aliceREPL.send("/status away")
                    _ = try await bob.waitForEvent { event in
                        if case let .presenceUpdated(from: _, presence) = event,
                           presence.show == .away {
                            return true
                        }
                        return false
                    }

                    // Cross-check the service-layer projection so a regression
                    // in `PresenceService.mapPresence` would fail the test
                    // even if the raw event passed through unchanged. The
                    // `@MainActor in` annotation hops the predicate onto the
                    // main actor because `presenceService` is `@MainActor`-
                    // isolated and the surrounding sending closure is not.
                    try await bob.waitForCondition({ @MainActor in
                        harness.environment.presenceService.contactPresences[aliceJID] == .away
                    }, timeout: TestTimeout.event)
                }
            }
        }

        @Test
        @MainActor func `REPL /status with no args echoes current presence`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                let aliceREPL = try await REPLSession.start(cli: cli, credentials: alice)
                await cli.addCleanup { await aliceREPL.terminate() }

                // Set a unique status+message first so the no-arg echo proves
                // it really read the current value (not just any default).
                let marker = "marker-\(UUID().uuidString.prefix(8))"
                try await aliceREPL.send("/status away \(marker)")
                // Wait for the formatted setup response (": <marker>" only
                // appears in the formatter output, not the PTY echo of the
                // user's input) — capturing the cursor before the setup
                // response drained would let the post-cursor wait below match
                // the warm-up output instead of the no-arg /status response.
                _ = try await aliceREPL.waitForOutput(containing: ": \(marker)")

                let cursor = await aliceREPL.cursor()
                try await aliceREPL.send("/status")
                _ = try await aliceREPL.waitForOutput(
                    containingAnyOf: [marker],
                    after: cursor
                )
            }
        }

        @Test
        @MainActor func `REPL /status rejects an unknown presence value`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                let aliceREPL = try await REPLSession.start(cli: cli, credentials: alice)
                await cli.addCleanup { await aliceREPL.terminate() }

                let cursor = await aliceREPL.cursor()
                try await aliceREPL.send("/status bogus-status")
                // `CLIError.invalidPresenceStatus` prefixes the unknown value
                // with "Invalid presence status: " (see `CLIError`).
                _ = try await aliceREPL.waitForOutput(
                    containingAnyOf: ["Invalid presence status: bogus-status"],
                    after: cursor
                )
            }
        }
    }
}
