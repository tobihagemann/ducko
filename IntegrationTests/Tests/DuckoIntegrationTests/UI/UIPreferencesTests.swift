import ApplicationServices
import Carbon.HIToolbox
import Foundation
import Testing

extension DuckoIntegrationTests.UILayer {
    struct UIPreferencesTests {
        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `cmd plus comma opens the preferences window`() async throws {
            try await UISeededApp.withSeededApp { app in
                try await app.waitForElement(identifier: "contact-list", timeout: TestTimeout.uiElement)
                try await app.pressKey(CGKeyCode(kVK_ANSI_Comma), modifiers: .maskCommand)
                try await app.waitForElement(
                    identifier: "preferences-window",
                    timeout: TestTimeout.uiElement
                )
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `accounts tab lists the seeded JID`() async throws {
            try await UISeededApp.withSeededApp { app in
                try await app.waitForElement(identifier: "contact-list", timeout: TestTimeout.uiElement)
                try await app.pressKey(CGKeyCode(kVK_ANSI_Comma), modifiers: .maskCommand)
                try await app.waitForElement(
                    identifier: "preferences-window",
                    timeout: TestTimeout.uiElement
                )

                try await app.clickTab(title: "Accounts", underIdentifier: "preferences-window")

                let alice = TestCredentials.alice
                let aliceVisible = try await app.containsDescendant(
                    role: kAXStaticTextRole as String,
                    withSubstring: alice.jid,
                    underIdentifier: "preferences-window"
                )
                #expect(aliceVisible)
            }
        }
    }
}
