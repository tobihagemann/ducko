import Foundation
import Testing

/// Pure-logic tests for `TestHarnessError.redactJIDs`. Locks in the privacy
/// contract that JIDs surfaced via Swift Testing's printed error
/// `description` are replaced with `<jid>`. Runs without AX trust or live
/// XMPP credentials so a regression that strips the redaction is caught in
/// plain `swift test --package-path IntegrationTests` runs.
enum TestHarnessErrorTests {
    struct Redaction {
        @Test func `plain JID redacts to placeholder`() {
            #expect(TestHarnessError.redactJIDs(in: "bob@example.com") == "<jid>")
        }

        @Test func `kebab identifier with embedded JID redacts only the JID`() {
            #expect(
                TestHarnessError.redactJIDs(in: "contact-row-bob@example.com")
                    == "contact-row-<jid>"
            )
        }

        /// Hyphens are ambiguous — they're valid in both kebab identifiers
        /// (separator) and RFC-7622 localparts (allowed char). The redactor
        /// tokenizes on `-`, so a hyphenated localpart leaks its leading
        /// hyphen-separated portion into the prefix. Documented limitation:
        /// test accounts in this repo (alice/bob/carol/dave) never have
        /// hyphens, so this is theoretical only.
        @Test func `hyphenated localpart leaks leading hyphen-separated portion`() {
            #expect(
                TestHarnessError.redactJIDs(in: "contact-row-bo-b@example.com")
                    == "contact-row-bo-<jid>"
            )
        }

        /// Same ambiguity for hyphenated domains.
        @Test func `hyphenated domain leaks trailing hyphen-separated portion`() {
            #expect(
                TestHarnessError.redactJIDs(in: "contact-row-bob@example-domain.com")
                    == "contact-row-<jid>-domain.com"
            )
        }

        @Test func `non-JID identifier passes through unchanged`() {
            #expect(TestHarnessError.redactJIDs(in: "contact-list") == "contact-list")
        }

        @Test func `multiple JIDs in one string redact each`() {
            #expect(
                TestHarnessError.redactJIDs(in: "from bob@example.com to alice@example.org")
                    == "from <jid> to <jid>"
            )
        }

        @Test func `empty string passes through unchanged`() {
            #expect(TestHarnessError.redactJIDs(in: "") == "")
        }

        @Test func `elementNotFound description redacts JID identifier`() {
            let err = TestHarnessError.elementNotFound(identifier: "contact-row-bob@example.com")
            #expect(err.description == "TestHarnessError.elementNotFound(contact-row-<jid>)")
        }

        @Test func `nonZeroExit description redacts JIDs in stdout and stderr`() {
            let err = TestHarnessError.nonZeroExit(
                code: 1,
                reason: .exit,
                stdout: "delivered to bob@example.com",
                stderr: "from alice@example.org"
            )
            #expect(err.description.contains("<jid>"))
            #expect(!err.description.contains("bob@example.com"))
            #expect(!err.description.contains("alice@example.org"))
        }

        @Test func `axActionFailed description includes redacted identifier, action, and axError`() {
            let err = TestHarnessError.axActionFailed(
                identifier: "chat-bubble-bob@example.com",
                action: "AXPress",
                axError: -25204
            )
            #expect(
                err.description
                    == "TestHarnessError.axActionFailed(chat-bubble-<jid>, action: AXPress, axError: -25204)"
            )
        }

        @Test func `axActionFailed description redacts JID embedded in identifier`() {
            let err = TestHarnessError.axActionFailed(
                identifier: "contact-row-alice@example.org",
                action: "AXPress",
                axError: -25200
            )
            #expect(err.description.contains("<jid>"))
            #expect(!err.description.contains("alice@example.org"))
        }

        @Test func `axActionFailed round-trips through Equatable`() {
            let lhs = TestHarnessError.axActionFailed(
                identifier: "search-contacts",
                action: "AXPress",
                axError: -25204
            )
            let rhs = TestHarnessError.axActionFailed(
                identifier: "search-contacts",
                action: "AXPress",
                axError: -25204
            )
            let different = TestHarnessError.axActionFailed(
                identifier: "search-contacts",
                action: "AXPress",
                axError: -25205
            )
            #expect(lhs == rhs)
            #expect(lhs != different)
        }

        @Test func `nonZeroExit signal vs exit is disambiguated in description`() {
            let exitErr = TestHarnessError.nonZeroExit(
                code: 13, reason: .exit, stdout: "", stderr: ""
            )
            let signalErr = TestHarnessError.nonZeroExit(
                code: 13, reason: .uncaughtSignal, stdout: "", stderr: ""
            )
            #expect(exitErr.description.contains("reason: exit"))
            #expect(signalErr.description.contains("reason: signal"))
            #expect(exitErr.description != signalErr.description)
        }
    }
}
