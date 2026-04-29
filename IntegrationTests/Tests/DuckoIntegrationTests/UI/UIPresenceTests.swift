import Foundation
import Testing

extension DuckoIntegrationTests.UILayer {
    struct UIPresenceTests {
        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `selecting a status updates the picker`() async throws {
            try await UISeededApp.withSeededApp { app in
                try await app.waitForElement(identifier: "status-picker", timeout: TestTimeout.uiElement)

                try await app.pickPopUpItem(title: "Away", identifier: "status-picker")

                let value = try await app.value(identifier: "status-picker")
                #expect(value == "Away")

                // No in-app reset cleanup needed: `terminate()` drops the
                // XMPP connection, the server marks alice unavailable, and
                // the per-test profile directory is reaped post-exit.
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `pickPopUpItem dismisses the menu when the requested item is missing`() async throws {
            try await UISeededApp.withSeededApp { app in
                try await app.waitForElement(identifier: "status-picker", timeout: TestTimeout.uiElement)

                // Bogus title makes `pickPopUpItem` open the menu, fail to
                // find a matching item, and recover by posting Escape so the
                // orphaned menu doesn't poison subsequent helper calls.
                await #expect(throws: TestHarnessError.self) {
                    try await app.pickPopUpItem(title: "NotARealStatus", identifier: "status-picker")
                }

                // If Escape recovery worked the picker is interactive again
                // and a real selection still commits cleanly.
                try await app.pickPopUpItem(title: "Away", identifier: "status-picker")
                let value = try await app.value(identifier: "status-picker")
                #expect(value == "Away")
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `setting a status message updates the field`() async throws {
            try await UISeededApp.withSeededApp { app in
                try await app.waitForElement(identifier: "status-message-field", timeout: TestTimeout.uiElement)

                try await app.type("Working", intoIdentifier: "status-message-field")
                try await app.pressReturn(intoIdentifier: "status-message-field")

                let value = try await app.value(identifier: "status-message-field")
                #expect(value == "Working")
            }
        }
    }
}
