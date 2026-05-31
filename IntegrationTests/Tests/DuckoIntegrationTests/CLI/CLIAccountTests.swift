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
        @MainActor func `account add --no-connect persists the account offline`() async throws {
            try await CLIProcess.withProcess { cli in
                // A closed loopback endpoint is never reached: `seedUnreachableAccount`
                // runs `account add … --no-connect` and its clean-exit guard proves no
                // connect was attempted; the list assertion proves the account persisted.
                let port = try CLIProcess.reserveClosedLoopbackPort()
                try await cli.seedUnreachableAccount(
                    jid: "offline@example.com", host: "127.0.0.1", port: port
                )

                let listed = try await cli.run(["account", "list", "--output", "plain"])
                #expect(listed.exitCode == 0)
                #expect(listed.stdout.contains("offline@example.com"))
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
        @MainActor func `account delete matches a case-variant JID`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                // Lookups normalize through BareJID, so an upper-cased JID
                // resolves to the stored (case-folded) account.
                let deleted = try await cli.run(["account", "delete", alice.jid.uppercased()])
                #expect(deleted.exitCode == 0)

                let listed = try await cli.run(["account", "list", "--output", "plain"])
                #expect(listed.exitCode == 0)
                #expect(listed.stdout.contains("No accounts configured."))
            }
        }

        @Test
        @MainActor func `account unregister matches a case-variant JID before confirming`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                // Decline the confirmation so the account is only resolved (proving
                // the case-variant lookup matched) and never unregistered on the server.
                let output = try await cli.run(
                    ["account", "unregister", alice.jid.uppercased()],
                    stdin: "no\n"
                )
                #expect(output.exitCode == 0)
                #expect(output.stdout.contains("Cancelled."))
            }
        }

        @Test
        @MainActor func `account delete reports an error for an invalid JID`() async throws {
            try await CLIProcess.withProcess { cli in
                // A bare JID cannot carry a resource, so this is rejected by
                // BareJID parsing before any account lookup.
                let output = try await cli.run(["account", "delete", "alice@example.com/resource"])
                #expect(output.exitCode != 0)
                #expect(output.stderr.contains("Invalid JID"))
            }
        }

        @Test
        @MainActor func `account add rejects a duplicate JID`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                // The duplicate guard rejects before any connection, so the
                // password is never consumed — a placeholder keeps the real
                // credential out of the child process argv.
                let duplicate = try await cli.run([
                    "account", "add", alice.jid, "--password", "unused"
                ])
                #expect(duplicate.exitCode != 0)
                #expect(duplicate.stderr.contains("already exists"))

                let listed = try await cli.run(["account", "list", "--output", "plain"])
                #expect(listed.exitCode == 0)
                let matches = listed.stdout
                    .split(separator: "\n")
                    .filter { $0.contains(alice.jid) }
                #expect(matches.count == 1)
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

        @Test
        @MainActor func `account delete leaves an unrelated account untouched`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                let bob = TestCredentials.bob
                try await cli.seedAccount(alice)

                let output = try await cli.run(["account", "delete", bob.jid])
                #expect(output.exitCode != 0)
                #expect(output.stderr.contains("Account not found: \(bob.jid)"))

                let listed = try await cli.run(["account", "list", "--output", "plain"])
                #expect(listed.exitCode == 0)
                #expect(listed.stdout.contains(alice.jid))
            }
        }
    }
}
