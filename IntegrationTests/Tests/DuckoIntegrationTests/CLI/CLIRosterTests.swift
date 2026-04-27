import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIRosterTests {
        @Test
        @MainActor func `roster list reports current contacts`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                let listed = try await cli.run(["roster", "list", "--output", "json"])
                #expect(listed.exitCode == 0)

                // Each non-empty line is one flat [String: String] JSON
                // object with a "type" discriminator (see
                // `JSONFormatterTests`). Don't assert a specific
                // contact: the alice baseline is operator-managed (see
                // `TestCredentials`) and may be empty on fresh setups.
                let lines = listed.stdout.split(separator: "\n", omittingEmptySubsequences: true)
                for line in lines {
                    let data = try #require(String(line).data(using: .utf8))
                    _ = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
                }
            }
        }

        @Test(.enabled(if: TestCredentials.isDaveAvailable, "Dave credentials missing"))
        @MainActor func `roster add inserts a contact`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                let dave = TestCredentials.dave
                try await cli.seedAccount(alice)

                // Register cleanup before the mutation so a thrown
                // assertion or a transient server failure can't leave
                // dave in alice's real roster across runs (mirrors
                // `Protocol/RosterTests`).
                await cli.addCleanup {
                    _ = try? await cli.run(["roster", "remove", dave.jid])
                }

                let rosterAdd = try await cli.run(["roster", "add", dave.jid])
                #expect(rosterAdd.exitCode == 0)

                let listed = try await cli.run(["roster", "list", "--output", "plain"])
                #expect(listed.exitCode == 0)
                #expect(listed.stdout.contains(dave.jid))
            }
        }

        @Test(.enabled(if: TestCredentials.isDaveAvailable, "Dave credentials missing"))
        @MainActor func `roster remove deletes a contact`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                let dave = TestCredentials.dave
                try await cli.seedAccount(alice)

                // Belt-and-braces cleanup so neither the add-then-throw path
                // (after add succeeds) nor the post-remove-then-throw path
                // (after the remove returns success but a later assertion
                // throws) can leave dave in alice's roster.
                await cli.addCleanup {
                    _ = try? await cli.run(["roster", "remove", dave.jid])
                }

                let rosterAdd = try await cli.run(["roster", "add", dave.jid])
                #expect(rosterAdd.exitCode == 0)

                let rosterRemove = try await cli.run(["roster", "remove", dave.jid])
                #expect(rosterRemove.exitCode == 0)

                let listed = try await cli.run(["roster", "list", "--output", "plain"])
                #expect(listed.exitCode == 0)
                #expect(!listed.stdout.contains(dave.jid))
            }
        }
    }
}
