import Foundation

/// XMPP test account credentials sourced from environment variables.
///
/// On first access, falls back to parsing `IntegrationTests/.env.test` (adjacent
/// to this nested package's `Package.swift`) so callers do not need to `source`
/// the file before running `swift test --package-path IntegrationTests`. Existing
/// environment variables always win — sourcing in the shell still overrides.
///
/// Integration tests skip cleanly when these are unset (`isAvailable == false`),
/// so the test target builds and runs in CI without requiring secrets.
///
/// ## Test account preconditions
///
/// The specialized-protocol test suites assume baseline state on the operator-
/// managed accounts. Tests fail fast via `#require` when the baseline is
/// missing — they do not silently skip.
///
/// - **Mutual roster subscription between alice ↔ bob and alice ↔ carol.**
///   Required so PEP+ avatar-metadata notifications flow across accounts
///   (`AvatarTests`). Recommended for any future test that needs PEP fan-out.
/// - **Pre-published vCard on alice.** Required by `ProfileTests`: the suite
///   round-trips an existing profile because `ProfileService` has no delete
///   API, so a "synthesize then restore" path would leak vCard state
///   server-side. `AvatarTests` publishes and restores each account's avatar
///   within the test body, so no avatar baseline is required.
/// - **Dave has no baseline subscription with any other account.** Required by
///   `RosterTests` subscription/denial mutation tests so alice↔bob and
///   alice↔carol baselines are never mutated.
enum TestCredentials {
    struct Credential {
        let jid: String
        let password: String
        let label: String
    }

    static let mucService = "conference.xmpp.tobiha.de"

    /// Baseline gate for the root integration suite — requires Alice, Bob, Carol.
    /// Dave is a newer addition; requiring him here would skip every existing
    /// integration test in environments that have only the three-account baseline.
    static var isAvailable: Bool {
        env("DUCKO_TEST_ALICE_JID") != nil
            && env("DUCKO_TEST_ALICE_PASSWORD") != nil
            && env("DUCKO_TEST_BOB_JID") != nil
            && env("DUCKO_TEST_BOB_PASSWORD") != nil
            && env("DUCKO_TEST_CAROL_JID") != nil
            && env("DUCKO_TEST_CAROL_PASSWORD") != nil
    }

    /// Narrower gate applied only to roster subscription/denial tests that
    /// depend on Dave's clean-roster baseline.
    static var isDaveAvailable: Bool {
        env("DUCKO_TEST_DAVE_JID") != nil
            && env("DUCKO_TEST_DAVE_PASSWORD") != nil
    }

    static var alice: Credential {
        credential(jidVar: "DUCKO_TEST_ALICE_JID", passwordVar: "DUCKO_TEST_ALICE_PASSWORD", label: "alice")
    }

    static var bob: Credential {
        credential(jidVar: "DUCKO_TEST_BOB_JID", passwordVar: "DUCKO_TEST_BOB_PASSWORD", label: "bob")
    }

    static var carol: Credential {
        credential(jidVar: "DUCKO_TEST_CAROL_JID", passwordVar: "DUCKO_TEST_CAROL_PASSWORD", label: "carol")
    }

    static var dave: Credential {
        credential(jidVar: "DUCKO_TEST_DAVE_JID", passwordVar: "DUCKO_TEST_DAVE_PASSWORD", label: "dave")
    }

    private static func credential(jidVar: String, passwordVar: String, label: String) -> Credential {
        Credential(jid: env(jidVar) ?? "", password: env(passwordVar) ?? "", label: label)
    }

    private static func env(_ key: String) -> String? {
        _ = loadEnvFileOnce
        return ProcessInfo.processInfo.environment[key]
    }

    private static let loadEnvFileOnce: Void = loadEnvFile()

    private static func loadEnvFile() {
        // TestCredentials.swift lives at:
        //   IntegrationTests/Tests/DuckoIntegrationTests/TestCredentials.swift
        // .env.test lives at:
        //   IntegrationTests/.env.test
        let envFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DuckoIntegrationTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // IntegrationTests
            .appendingPathComponent(".env.test")

        guard let contents = try? String(contentsOf: envFile, encoding: .utf8) else { return }

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let eq = line.firstIndex(of: "=") else { continue }

            let key = line[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2) ||
                (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2) {
                value = String(value.dropFirst().dropLast())
            }

            if ProcessInfo.processInfo.environment[key] == nil {
                setenv(key, value, 1)
            }
        }
    }
}
