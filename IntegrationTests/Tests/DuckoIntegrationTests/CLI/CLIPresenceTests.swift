import DuckoCore
import DuckoXMPP
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
                let bobRoster = try await harness.module(RosterModule.self, for: "bob")
                harness.addCleanup { try? await bobRoster.removeContact(jid: aliceJID) }

                try await CLIProcess.withProcess { aliceCLI in
                    let aliceREPL = try await REPLSession.start(cli: aliceCLI, credentials: TestCredentials.alice)
                    await aliceCLI.addCleanup { await aliceREPL.terminate() }

                    // Bob asks to see alice's presence; alice's REPL surfaces the request.
                    try await bobRoster.subscribe(to: aliceJID)
                    _ = try await aliceREPL.waitForOutput(
                        containing: "Subscription request from \(bobJID)",
                        timeout: TestTimeout.event
                    )

                    // RFC 6121 §3.1.5: alice's `subscribed` push installs a
                    // roster item on alice's side, so the approval flow does
                    // mutate alice's roster. Register the cleanup before the
                    // mutation, mirroring `harness.addCleanup` ordering above.
                    await aliceCLI.addCleanup {
                        try? await aliceREPL.send("/remove \(bobJID)")
                    }
                    try await aliceREPL.send("/approve \(bobJID)")

                    _ = try await bob.waitForEvent { event in
                        if case let .presenceSubscriptionApproved(from) = event, from == aliceJID {
                            return true
                        }
                        return false
                    }

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
    }
}
