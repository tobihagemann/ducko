import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIAccountTests {
        @Test
        @MainActor func `account list reports no accounts when none configured`() async throws {
            try await CLIProcess.withProcess { cli in
                let output = try await cli.run(["account", "list", "--output", "plain"])
                #expect(output.exitCode == 0)
                #expect(output.stdout.contains("No accounts configured."))
            }
        }

        @Test
        @MainActor func `account add stores a new account`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                let listed = try await cli.run(["account", "list", "--output", "plain"])
                #expect(listed.exitCode == 0)
                #expect(listed.stdout.contains(alice.jid))
            }
        }

        @Test
        @MainActor func `account delete removes an account`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                let deleted = try await cli.run(["account", "delete", alice.jid])
                #expect(deleted.exitCode == 0)

                let listed = try await cli.run(["account", "list", "--output", "plain"])
                #expect(listed.exitCode == 0)
                #expect(listed.stdout.contains("No accounts configured."))
            }
        }

        @Test
        @MainActor func `account delete reports an error for an unknown JID`() async throws {
            try await CLIProcess.withProcess { cli in
                // No `seedAccount` here — `accountService.accounts` is empty,
                // so `Account.Delete.run` throws `CLIError.accountNotFound(jid)`,
                // whose description reads "Account not found: <jid>".
                // ArgumentParser routes throws to stderr with a non-zero exit.
                let alice = TestCredentials.alice
                let output = try await cli.run(["account", "delete", alice.jid])
                #expect(output.exitCode != 0)
                #expect(output.stderr.contains("Account not found: \(alice.jid)"))
            }
        }
    }
}
