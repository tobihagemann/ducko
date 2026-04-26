import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIOutputFormatTests {
        @Test(.enabled(if: CLIProcess.binaryExists, "DuckoCLI binary missing"))
        @MainActor func `ducko send --output json emits a message JSON object`() async throws {
            let aliceProfile = "inttest-alice-\(UUID().uuidString.prefix(8))"
            let bobProfile = "inttest-bob-\(UUID().uuidString.prefix(8))"

            try await CLIProcess.withProcess(profile: aliceProfile) { aliceCLI in
                try await CLIProcess.withProcess(profile: bobProfile) { bobCLI in
                    let alice = TestCredentials.alice
                    let bob = TestCredentials.bob

                    // Bob's account is added so the recipient is registered server-side
                    // and ready for delivery; no REPL is needed for this assertion since
                    // we only validate alice's emitted JSON.
                    try await bobCLI.seedAccount(bob)
                    try await aliceCLI.seedAccount(alice)

                    let body = "msg-\(UUID().uuidString.prefix(8))"
                    let output = try await aliceCLI.run([
                        "send", bob.jid, body, "--output", "json"
                    ])
                    #expect(output.exitCode == 0)

                    // `JSONFormatter` emits one flat `[String: String]` JSON object
                    // per line with a `"type"` discriminator
                    // (`Tests/DuckoCLITests/JSONFormatterTests.swift:10-29`).
                    let lines = output.stdout.split(separator: "\n", omittingEmptySubsequences: true)
                    var sawMessage = false
                    for line in lines {
                        let data = try #require(String(line).data(using: .utf8))
                        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                            continue
                        }
                        if dict["type"] == "message", dict["body"] == body {
                            sawMessage = true
                            break
                        }
                    }
                    #expect(sawMessage, "expected a message JSON object with body=\(body) in stdout, got: \(output.stdout)")
                }
            }
        }

        @Test(.enabled(if: CLIProcess.binaryExists, "DuckoCLI binary missing"))
        @MainActor func `roster list --output plain emits human-readable text`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                let listed = try await cli.run(["roster", "list", "--output", "plain"])
                #expect(listed.exitCode == 0)
                let trimmed = listed.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                // Plain output never starts with `{` (which would indicate JSON) and
                // never contains ANSI escape sequences. `OutputFormat.swift:14-15`
                // defaults to plain when stdout is a `Pipe` (not a TTY), so the
                // explicit `--output plain` here just pins the format.
                // Positive marker: `PlainFormatter.formatGroupHeader`
                // (`PlainFormatter.swift:53-55`) emits `--- <name> (<count>) ---`
                // for non-empty rosters, or `DuckoCLI.swift:2401-2404` prints
                // "No contacts in roster." for the empty baseline. Asserting one
                // of these is present rules out a vacuously-passing empty stdout.
                #expect(trimmed.contains("---") || trimmed.contains("No contacts in roster."))
                #expect(!trimmed.hasPrefix("{"))
                #expect(!listed.stdout.contains("\u{1B}["))
            }
        }
    }
}
