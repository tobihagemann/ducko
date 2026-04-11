import Foundation

/// XMPP test account credentials sourced from environment variables.
///
/// Integration tests skip cleanly when these are unset (`isAvailable == false`),
/// so the test target builds and runs in CI without requiring secrets.
enum TestCredentials {
    struct Credential {
        let jid: String
        let password: String
    }

    // periphery:ignore - reserved for MUC tests
    static let mucService = "conference.xmpp.tobiha.de"

    static var isAvailable: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["DUCKO_TEST_ALICE_JID"] != nil
            && env["DUCKO_TEST_ALICE_PASSWORD"] != nil
            && env["DUCKO_TEST_BOB_JID"] != nil
            && env["DUCKO_TEST_BOB_PASSWORD"] != nil
            && env["DUCKO_TEST_CAROL_JID"] != nil
            && env["DUCKO_TEST_CAROL_PASSWORD"] != nil
    }

    static var alice: Credential {
        credential(jidVar: "DUCKO_TEST_ALICE_JID", passwordVar: "DUCKO_TEST_ALICE_PASSWORD")
    }

    static var bob: Credential {
        credential(jidVar: "DUCKO_TEST_BOB_JID", passwordVar: "DUCKO_TEST_BOB_PASSWORD")
    }

    // periphery:ignore - reserved for multi-account MUC tests
    static var carol: Credential {
        credential(jidVar: "DUCKO_TEST_CAROL_JID", passwordVar: "DUCKO_TEST_CAROL_PASSWORD")
    }

    private static func credential(jidVar: String, passwordVar: String) -> Credential {
        let env = ProcessInfo.processInfo.environment
        return Credential(jid: env[jidVar] ?? "", password: env[passwordVar] ?? "")
    }
}
