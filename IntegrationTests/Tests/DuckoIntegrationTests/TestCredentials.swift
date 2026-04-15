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
enum TestCredentials {
    struct Credential {
        let jid: String
        let password: String
    }

    static let mucService = "conference.xmpp.tobiha.de"

    static var isAvailable: Bool {
        env("DUCKO_TEST_ALICE_JID") != nil
            && env("DUCKO_TEST_ALICE_PASSWORD") != nil
            && env("DUCKO_TEST_BOB_JID") != nil
            && env("DUCKO_TEST_BOB_PASSWORD") != nil
            && env("DUCKO_TEST_CAROL_JID") != nil
            && env("DUCKO_TEST_CAROL_PASSWORD") != nil
    }

    static var alice: Credential {
        credential(jidVar: "DUCKO_TEST_ALICE_JID", passwordVar: "DUCKO_TEST_ALICE_PASSWORD")
    }

    static var bob: Credential {
        credential(jidVar: "DUCKO_TEST_BOB_JID", passwordVar: "DUCKO_TEST_BOB_PASSWORD")
    }

    static var carol: Credential {
        credential(jidVar: "DUCKO_TEST_CAROL_JID", passwordVar: "DUCKO_TEST_CAROL_PASSWORD")
    }

    private static func credential(jidVar: String, passwordVar: String) -> Credential {
        Credential(jid: env(jidVar) ?? "", password: env(passwordVar) ?? "")
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
