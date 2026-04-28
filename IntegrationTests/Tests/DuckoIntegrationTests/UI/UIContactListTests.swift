import Foundation
import Testing

extension DuckoIntegrationTests.UILayer {
    struct UIContactListTests {
        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `contact list shows a known peer after auto-connect`() async throws {
            try await UISeededApp.withSeededApp { app in
                let bob = TestCredentials.bob
                try await app.waitForElement(identifier: "contact-row-\(bob.jid)")
                let value = try await app.value(identifier: "contact-row-\(bob.jid)")
                #expect(value != nil)
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `searching the contact list filters to a matching JID`() async throws {
            try await UISeededApp.withSeededApp { app in
                let bob = TestCredentials.bob
                try await app.waitForElement(identifier: "contact-row-\(bob.jid)")

                // Negative case first: a query that matches no contact must
                // hide bob's row. Without this, a no-op `.searchable` would
                // pass the matching-query check below trivially.
                try await app.type("zzznomatch", intoSearchField: nil)
                try await app.waitForAbsence(
                    identifier: "contact-row-\(bob.jid)",
                    timeout: TestTimeout.uiElement
                )

                // Positive case: typing "bob" surfaces bob's row again.
                // Replace the search text — the keystroke fallback would
                // append, so we set the kAXValueAttribute path explicitly.
                try await app.type("bob", intoSearchField: nil)
                try await app.waitForElement(
                    identifier: "contact-row-\(bob.jid)",
                    timeout: TestTimeout.uiElement
                )
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `right-clicking a contact row opens the context menu`() async throws {
            try await UISeededApp.withSeededApp { app in
                let bob = TestCredentials.bob
                try await app.waitForElement(identifier: "contact-row-\(bob.jid)")
                try await app.rightClick(identifier: "contact-row-\(bob.jid)")
                try await app.waitForElement(
                    identifier: "send-directed-presence-menu-item",
                    timeout: TestTimeout.uiElement
                )
            }
        }
    }
}
