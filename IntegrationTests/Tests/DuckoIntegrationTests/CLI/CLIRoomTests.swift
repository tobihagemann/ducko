import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIRoomTests {
        @Test(.enabled(if: CLIProcess.binaryExists, "DuckoCLI binary missing"))
        @MainActor func `REPL /join enters a MUC room`() async throws {
            try await CLIProcess.withProcess { aliceCLI in
                let alice = TestCredentials.alice
                let aliceREPL = try await REPLSession.start(cli: aliceCLI, credentials: alice)
                await aliceCLI.addCleanup { await aliceREPL.terminate() }

                let roomJID = Self.makeEphemeralRoomJID()
                try await aliceREPL.send("/join \(roomJID)")

                // Register /destroy cleanup BEFORE the join confirmation wait
                // — if the join succeeded server-side but the wait misses, the
                // locked `inttest-*` room would otherwise linger on the live
                // server. Cleanup runs LIFO, so this fires before the REPL
                // terminate() registered above.
                await aliceCLI.addCleanup {
                    try? await aliceREPL.send("/destroy")
                }

                _ = try await aliceREPL.waitForOutput(
                    containing: "Joined ",
                    timeout: TestTimeout.event
                )
            }
        }

        @Test(.enabled(if: CLIProcess.binaryExists, "DuckoCLI binary missing"))
        @MainActor func `ducko room send delivers a group message via the CLI`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                // Harness creates and unlocks the room (`acceptDefaultConfig`
                // runs on `isNewlyCreated`, `TestHarness.swift:188-191`) so
                // bob's REPL and alice's CLI process can both join it.
                let roomJID = try await harness.createEphemeralRoom(using: "alice")

                try await CLIProcess.withProcess { aliceCLI in
                    try await CLIProcess.withProcess { bobCLI in
                        let alice = TestCredentials.alice
                        let bob = TestCredentials.bob

                        try await aliceCLI.seedAccount(alice)

                        let bobREPL = try await REPLSession.start(cli: bobCLI, credentials: bob)
                        await bobCLI.addCleanup { await bobREPL.terminate() }

                        try await bobREPL.send("/join \(roomJID.description)")
                        _ = try await bobREPL.waitForOutput(
                            containing: "Joined ",
                            timeout: TestTimeout.event
                        )

                        // Drive the actual `DuckoCLI.Room.Send` surface
                        // (`DuckoCLI.swift:651-697`): it joins → sends → leaves.
                        // Use a distinct nickname so this second alice session
                        // does not collide with the harness alice already in
                        // the room as "alice" (`TestHarness.swift:162`).
                        let body = "msg-\(UUID().uuidString.prefix(8))"
                        let sent = try await aliceCLI.run([
                            "room", "send", roomJID.description, body,
                            "--nickname", "alice-cli",
                            "--output", "plain"
                        ])
                        #expect(sent.exitCode == 0)

                        _ = try await bobREPL.waitForOutput(
                            containing: body,
                            timeout: TestTimeout.event
                        )
                    }
                }
            }
        }

        @Test(.enabled(if: CLIProcess.binaryExists, "DuckoCLI binary missing"))
        @MainActor func `REPL room send delivers a group message`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                // `createEphemeralRoom` calls `mucModule.acceptDefaultConfig` after a
                // newly-created room (`TestHarness.swift:188-191`), so subsequent joins
                // by non-owners succeed. The CLI REPL has no `/config submit-default`
                // surface, so this hybrid setup is the only way to exercise two-actor
                // room flows from the CLI layer today.
                let roomJID = try await harness.createEphemeralRoom(using: "alice")
                let aliceAccount = try #require(harness.accounts["alice"])

                try await CLIProcess.withProcess { bobCLI in
                    let bob = TestCredentials.bob
                    let bobREPL = try await REPLSession.start(cli: bobCLI, credentials: bob)
                    await bobCLI.addCleanup { await bobREPL.terminate() }

                    try await bobREPL.send("/join \(roomJID.description)")
                    _ = try await bobREPL.waitForOutput(
                        containing: "Joined ",
                        timeout: TestTimeout.event
                    )

                    // Drive alice's send through the in-process service: the regular-REPL
                    // `send <jid> <body>` form (`DuckoCLI.swift:2384-2390`) only routes to
                    // `sendGroupMessage` when that REPL's own `roomParticipants[jidString]`
                    // is non-empty, which requires the sending REPL to have /join'd. Alice
                    // has no REPL counterpart in this hybrid setup.
                    let body = "msg-\(UUID().uuidString.prefix(8))"
                    try await harness.environment.chatService.sendGroupMessage(
                        toJIDString: roomJID.description,
                        body: body,
                        accountID: aliceAccount.accountID
                    )

                    _ = try await bobREPL.waitForOutput(
                        containing: body,
                        timeout: TestTimeout.event
                    )
                }
            }
        }

        @Test(.enabled(if: CLIProcess.binaryExists, "DuckoCLI binary missing"))
        @MainActor func `REPL /leave exits the room`() async throws {
            try await CLIProcess.withProcess { aliceCLI in
                let alice = TestCredentials.alice
                let aliceREPL = try await REPLSession.start(cli: aliceCLI, credentials: alice)
                await aliceCLI.addCleanup { await aliceREPL.terminate() }

                let roomJID = Self.makeEphemeralRoomJID()
                try await aliceREPL.send("/join \(roomJID)")

                // The test body sends `/leave` mid-flight, which clears the
                // REPL's `currentRoom` and renders a follow-up `/destroy`
                // a no-op. Cleanup re-joins so it can still destroy the
                // (locked) room rather than leaving it server-side. Wait on
                // the join confirmation rather than a fixed sleep so cleanup
                // succeeds against a slow server roundtrip without flaking on
                // a fast one.
                await aliceCLI.addCleanup {
                    try? await aliceREPL.send("/join \(roomJID)")
                    _ = try? await aliceREPL.waitForOutput(
                        containing: "Joined ",
                        timeout: TestTimeout.event
                    )
                    try? await aliceREPL.send("/destroy")
                }

                _ = try await aliceREPL.waitForOutput(
                    containing: "Joined ",
                    timeout: TestTimeout.event
                )

                try await aliceREPL.send("/leave")
                _ = try await aliceREPL.waitForOutput(
                    containing: "Left ",
                    timeout: TestTimeout.event
                )
            }
        }

        @Test(.enabled(if: CLIProcess.binaryExists, "DuckoCLI binary missing"))
        @MainActor func `REPL /members lists occupants`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                // Same hybrid shape as the room-send test — alice creates the room
                // in-process (so `acceptDefaultConfig` runs), bob joins via REPL.
                let roomJID = try await harness.createEphemeralRoom(using: "alice")

                try await CLIProcess.withProcess { bobCLI in
                    let bob = TestCredentials.bob
                    let bobREPL = try await REPLSession.start(cli: bobCLI, credentials: bob)
                    await bobCLI.addCleanup { await bobREPL.terminate() }

                    try await bobREPL.send("/join \(roomJID.description)")
                    _ = try await bobREPL.waitForOutput(
                        containing: "Joined ",
                        timeout: TestTimeout.event
                    )

                    try await bobREPL.send("/members")
                    // Alice's nickname in the harness is "alice"
                    // (`TestHarness.swift:162`'s `nickname: label`).
                    _ = try await bobREPL.waitForOutput(
                        containing: "alice",
                        timeout: TestTimeout.event
                    )
                }
            }
        }

        @Test(.disabled("REPL has no /kick command; chatService.kickOccupant is unexposed — see plan §Risk: Kick gap"))
        @MainActor func `alice kicks bob from the room`() {
            // Implementation deferred until /kick or chatService.kickOccupant exposure lands.
        }

        // MARK: - Helpers

        private static func makeEphemeralRoomJID() -> String {
            // Lowercase so the JID matches what the server normalizes
            // localparts to (XMPP nodeprep). The CLI REPL's
            // `waitForRoomJoined` (`Sources/DuckoCLI/Helpers/RoomHelpers.swift:8`)
            // looks up `chatService.roomParticipants[roomJID]` by raw string
            // — passing an uppercase UUID prefix wedges that helper for its
            // full 15 s timeout, which races the test's `/leave` wait.
            "inttest-\(UUID().uuidString.prefix(8).lowercased())@\(TestCredentials.mucService)"
        }
    }
}
