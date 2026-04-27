import Foundation
import Testing

extension DuckoIntegrationTests.UILayer {
    struct UILoginTests {
        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted,
            "Ducko.app missing or AX trust not granted"
        ))
        @MainActor func `account setup logs in via the welcome screen`() async throws {
            let profile = "inttest-ui-\(UUID().uuidString.prefix(8))"
            try await AppAccessor.withAppAccessor(profile: profile, target: .welcome) { app in
                // AccountSetupView defaults to .importAdium; the JID/password
                // fields and connect-button only exist in the .login branch.
                try await app.clickSegment(title: "Login", identifier: "setup-mode-picker")
                try await app.waitForElement(identifier: "jid-field", timeout: TestTimeout.uiElement)

                let alice = TestCredentials.alice
                try await app.type(alice.jid, intoIdentifier: "jid-field")
                try await app.type(alice.password, intoIdentifier: "password-field")
                try await app.click(identifier: "connect-button")

                try await app.waitForElement(identifier: "contact-list", timeout: TestTimeout.connect)
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted,
            "Ducko.app missing or AX trust not granted"
        ))
        @MainActor func `account setup with invalid password keeps the welcome screen`() async throws {
            let profile = "inttest-ui-\(UUID().uuidString.prefix(8))"
            try await AppAccessor.withAppAccessor(profile: profile, target: .welcome) { app in
                try await app.clickSegment(title: "Login", identifier: "setup-mode-picker")
                try await app.waitForElement(identifier: "jid-field", timeout: TestTimeout.uiElement)

                let alice = TestCredentials.alice
                try await app.type(alice.jid, intoIdentifier: "jid-field")
                try await app.type(alice.password + "-WRONG", intoIdentifier: "password-field")
                try await app.click(identifier: "connect-button")

                // Probe absence of contact-list — the connect should fail.
                do {
                    try await app.waitForElement(identifier: "contact-list", timeout: .seconds(3))
                    Issue.record("contact-list appeared with wrong password")
                } catch TestHarnessError.timeout {
                    // expected
                }

                // The setup picker should still be visible.
                try await app.waitForElement(identifier: "setup-mode-picker", timeout: .seconds(1))
            }
        }
    }
}
