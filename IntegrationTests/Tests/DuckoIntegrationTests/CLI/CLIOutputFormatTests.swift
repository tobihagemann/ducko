import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIOutputFormatTests {
        @Test
        @MainActor func `ducko send --output json emits a message JSON object`() async throws {
            try await CLIProcess.withProcessPair { aliceCLI, bobCLI in
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

                // `JSONFormatter` emits one flat `[String: String]` JSON
                // object per line with a `"type"` discriminator (see
                // `JSONFormatterTests`).
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

        @Test
        @MainActor func `roster list --output plain emits human-readable text`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                let listed = try await cli.run(["roster", "list", "--output", "plain"])
                #expect(listed.exitCode == 0)
                let trimmed = listed.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                // Plain output never starts with `{` (which would indicate
                // JSON) and never contains ANSI escape sequences.
                // `OutputFormat.defaultForTerminal` falls back to plain
                // when stdout is a `Pipe` (not a TTY), so the explicit
                // `--output plain` here just pins the format.
                // Positive marker: `PlainFormatter.formatGroupHeader`
                // emits `--- <name> (<count>) ---` for non-empty rosters,
                // or the REPL roster handler prints "No contacts in
                // roster." for the empty baseline. Asserting one of
                // these is present rules out a vacuously-passing empty
                // stdout.
                #expect(trimmed.contains("---") || trimmed.contains("No contacts in roster."))
                #expect(!trimmed.hasPrefix("{"))
                #expect(!listed.stdout.contains("\u{1B}["))
            }
        }

        @Test
        @MainActor func `account list --output ansi emits ANSI escape sequences`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                // Local-only assertion: `account list` reads accounts
                // from the local credential store and prints them
                // through the formatter without contacting the server.
                // `ANSIFormatter.formatAccount` always wraps the JID
                // and account UUID in `Color.bold`/`Color.dim` escapes,
                // so the `\u{1B}[` substring is guaranteed when
                // `--output ansi` overrides
                // `OutputFormat.defaultForTerminal`. Cheaper and less
                // flake-prone than driving `presence` through a live
                // connect/broadcast/disconnect cycle.
                let output = try await cli.run([
                    "account", "list", "--output", "ansi"
                ])
                #expect(output.exitCode == 0)
                #expect(output.stdout.contains("\u{1B}["))
            }
        }
    }
}
