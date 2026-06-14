import Carbon.HIToolbox
import Foundation
import Testing

extension DuckoIntegrationTests.UILayer {
    struct UIContactInfoTests {
        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `chat header info button opens the Contact Info window`() async throws {
            try await UISeededApp.withSeededApp { app in
                let bob = TestCredentials.bob
                try await app.waitForContactRow(bob)
                try await app.doubleClick(identifier: "contact-row-\(bob.jid)")
                try await app.waitForElement(identifier: "message-field", timeout: TestTimeout.uiElement)

                try await app.click(identifier: "contact-info-button")
                try await app.waitForElement(identifier: "contact-info-window", timeout: TestTimeout.uiElement)
                // The nickname field proves the Roster section rendered for the resolved contact.
                try await app.waitForElement(identifier: "contact-info-nickname-field", timeout: TestTimeout.uiElement)
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `contact context Get Info opens the Contact Info window`() async throws {
            try await UISeededApp.withSeededApp { app in
                let bob = TestCredentials.bob
                try await app.waitForContactRow(bob)
                try await app.rightClick(identifier: "contact-row-\(bob.jid)")
                try await app.contextMenuItem(title: "Get Info")
                try await app.waitForElement(identifier: "contact-info-window", timeout: TestTimeout.uiElement)
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `bottom tab bar retains a draft across tab switches`() async throws {
            try await UISeededApp.withSeededApp { app in
                let bob = TestCredentials.bob
                let carol = TestCredentials.carol
                let draft = "half typed message"

                // Open bob's chat — its tab appears in the bottom tab bar.
                try await app.waitForContactRow(bob)
                try await app.doubleClick(identifier: "contact-row-\(bob.jid)")
                try await app.waitForElement(identifier: "chat-tab-bar", timeout: TestTimeout.uiElement)
                try await app.waitForElement(identifier: "chat-tab-\(bob.jid)", timeout: TestTimeout.uiElement)

                // Type a draft into bob's composer but don't send it.
                try await app.clearAndType(draft, intoIdentifier: "message-field")

                // Open a second chat via New Chat (⌘N) so the draft tab stays open.
                try await app.pressKey(CGKeyCode(kVK_ANSI_N), modifiers: .maskCommand)
                try await app.waitForElement(identifier: "new-chat-jid-field", timeout: TestTimeout.uiElement)
                try await app.type(carol.jid, intoIdentifier: "new-chat-jid-field")
                try await app.click(identifier: "start-chat-button")
                try await app.waitForElement(identifier: "chat-tab-\(carol.jid)", timeout: TestTimeout.uiElement)

                // Switching back to bob's tab must restore the retained draft, not reset it.
                try await app.click(identifier: "chat-tab-\(bob.jid)")
                try await app.waitForValue(draft, identifier: "message-field")
            }
        }
    }
}
