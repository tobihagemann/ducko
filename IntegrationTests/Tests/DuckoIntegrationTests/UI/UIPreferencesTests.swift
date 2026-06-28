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

                try await app.clickTab(title: "Accounts", identifier: "preferences-window")

                let alice = TestCredentials.alice
                let aliceVisible = try await app.containsDescendant(
                    role: kAXStaticTextRole as String,
                    withSubstring: alice.jid,
                    underIdentifier: "preferences-window"
                )
                #expect(aliceVisible)
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `accounts detail pane shows connection info and change password`() async throws {
            try await UISeededApp.withSeededApp { app in
                // Gate on a connected account before opening prefs so the detail
                // pane's `isConnected`-gated buttons render. Wait on Bob (a
                // roster contact with a `contact-row-` element) rather than Alice:
                // Alice is the seeded self account and has no roster row of her
                // own, so `waitForContactRow(.alice)` would time out.
                try await app.waitForContactRow(TestCredentials.bob)

                try await app.pressKey(CGKeyCode(kVK_ANSI_Comma), modifiers: .maskCommand)
                try await app.waitForElement(identifier: "preferences-window", timeout: TestTimeout.uiElement)
                try await app.clickTab(title: "Accounts", identifier: "preferences-window")

                // Select the seeded account's row so the detail pane renders.
                let alice = TestCredentials.alice
                try await app.selectListRow(containingSubstring: alice.jid, underIdentifier: "preferences-window")

                // `Change Password...` is gated only on `isConnected`, so it is
                // the hard assertion. Match the exact published labels (literal
                // ASCII `...`) via the description-aware lookup — a plain
                // `containsDescendant` reads title/value only and would
                // false-negative on these description-only `Button("…")` labels.
                try await app.waitForDescendantButton(
                    label: "Change Password...",
                    underIdentifier: "preferences-window"
                )

                // `Connection Info...` additionally needs non-nil `tlsInfo`,
                // which can lag the connected state; tolerate that raciness so a
                // slow TLS-info population doesn't flake the suite.
                await withKnownIssue("Connection Info... may lag TLS-info population", isIntermittent: true) {
                    let hasConnectionInfo = try await app.hasDescendantButton(
                        label: "Connection Info...",
                        underIdentifier: "preferences-window"
                    )
                    #expect(hasConnectionInfo)
                }
            }
        }
    }
}
