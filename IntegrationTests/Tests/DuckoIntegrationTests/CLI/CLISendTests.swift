import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLISendTests {
        @Test(.enabled(if: CLIProcess.binaryExists, "DuckoCLI binary missing"))
        @MainActor func `ducko send delivers a message to bob's REPL`() async throws {
            let aliceProfile = "inttest-alice-\(UUID().uuidString.prefix(8))"
            let bobProfile = "inttest-bob-\(UUID().uuidString.prefix(8))"

            try await CLIProcess.withProcess(profile: aliceProfile) { aliceCLI in
                try await CLIProcess.withProcess(profile: bobProfile) { bobCLI in
                    let alice = TestCredentials.alice
                    let bob = TestCredentials.bob
                    try await aliceCLI.seedAccount(alice)

                    let bobREPL = try await REPLSession.start(cli: bobCLI, credentials: bob)
                    await bobCLI.addCleanup { await bobREPL.terminate() }

                    let body = "msg-\(UUID().uuidString.prefix(8))"
                    let sent = try await aliceCLI.run([
                        "send", bob.jid, body, "--output", "plain"
                    ])
                    #expect(sent.exitCode == 0)

                    _ = try await bobREPL.waitForOutput(containing: body, timeout: TestTimeout.replOutput)
                }
            }
        }

        @Test(.enabled(if: CLIProcess.binaryExists, "DuckoCLI binary missing"))
        @MainActor func `bidirectional REPL exchange round-trips messages`() async throws {
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

                    let outbound = "msg-\(UUID().uuidString.prefix(8))"
                    let reply = "msg-\(UUID().uuidString.prefix(8))"

                    try await aliceREPL.send("send \(bob.jid) \(outbound)")
                    _ = try await bobREPL.waitForOutput(containing: outbound, timeout: TestTimeout.replOutput)

                    try await bobREPL.send("send \(alice.jid) \(reply)")
                    _ = try await aliceREPL.waitForOutput(containing: reply, timeout: TestTimeout.replOutput)
                }
            }
        }

        @Test(.enabled(if: CLIProcess.binaryExists, "DuckoCLI binary missing"))
        @MainActor func `ducko send --file delivers a file to bob`() async throws {
            let aliceProfile = "inttest-alice-\(UUID().uuidString.prefix(8))"
            let bobProfile = "inttest-bob-\(UUID().uuidString.prefix(8))"

            try await CLIProcess.withProcess(profile: aliceProfile) { aliceCLI in
                try await CLIProcess.withProcess(profile: bobProfile) { bobCLI in
                    let alice = TestCredentials.alice
                    let bob = TestCredentials.bob

                    let fileNonce = UUID().uuidString
                    let fileURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ducko-inttest-fixture-\(fileNonce).txt", isDirectory: false)
                    let payload = String(repeating: "ducko-inttest-\(UUID().uuidString)\n", count: 64)
                    try payload.write(to: fileURL, atomically: true, encoding: .utf8)
                    await aliceCLI.addCleanup { try? FileManager.default.removeItem(at: fileURL) }

                    try await aliceCLI.seedAccount(alice)

                    let bobREPL = try await REPLSession.start(
                        cli: bobCLI, credentials: bob, arguments: ["--output", "plain"]
                    )
                    await bobCLI.addCleanup { await bobREPL.terminate() }

                    // Don't pass `--method jingle`: `sendFileViaJingle` rejects
                    // bare JIDs (`Sources/DuckoCore/Services/FileTransferService.swift:641-644`)
                    // and the test only has bob's bare JID to work with. The
                    // auto path uses HTTP File Upload (XEP-0363) and sends the
                    // resulting URL as a regular chat message; bob's REPL
                    // surfaces it via `formatIncomingMessage` rather than
                    // `formatFileOffer`. The asserted substring is the
                    // file's UUID nonce — present in the upload-server URL —
                    // so the assertion proves end-to-end delivery without
                    // depending on which formatter handler ran.
                    // Driving `/accept` and a completion marker requires
                    // Jingle, which requires full-JID peer resolution we
                    // can't seed from a bare-JID CLI invocation; tracked as
                    // a follow-up.
                    let sent = try await aliceCLI.run([
                        "send", "--file", fileURL.path, bob.jid,
                        "--output", "plain"
                    ], timeout: TestTimeout.fileTransfer)
                    #expect(sent.exitCode == 0)

                    _ = try await bobREPL.waitForOutput(
                        containing: fileNonce,
                        timeout: TestTimeout.fileTransfer
                    )
                }
            }
        }
    }
}
