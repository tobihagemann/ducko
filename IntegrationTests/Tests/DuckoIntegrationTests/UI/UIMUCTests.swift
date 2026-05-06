import ApplicationServices
import Foundation
import Testing

extension DuckoIntegrationTests.UILayer {
    struct UIMUCTests {
        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `joining a fresh room reaches the chat window`() async throws {
            try await UISeededApp.withSeededApp { app in
                _ = try await Self.joinAndUnlockRoom(app)
                try await app.waitForElement(identifier: "message-field", timeout: TestTimeout.uiElement)
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `messages exchanged in a room appear on both ends`() async throws {
            let bobProfile = "inttest-ui-bob-\(UUID().uuidString.prefix(8))"
            try await UISeededApp.withSeededApp { app in
                let roomJID = try await Self.joinAndUnlockRoom(app)

                try await CLIProcess.withProcess(profile: bobProfile) { bobCLI in
                    let bobREPL = try await REPLSession.start(cli: bobCLI, credentials: TestCredentials.bob)
                    await bobCLI.addCleanup { await bobREPL.terminate() }

                    // Bob joins first so live delivery wins (MUC's default
                    // history mode emits no replay request).
                    try await bobREPL.send("/join \(roomJID)")
                    _ = try await bobREPL.waitForOutput(containing: "Joined", timeout: TestTimeout.connect)

                    let body = "muc-\(UUID().uuidString.prefix(8))"
                    try await app.type(body, intoIdentifier: "message-field")
                    try await app.pressReturn(intoIdentifier: "message-field")

                    try await app.waitForDescendant(
                        role: kAXStaticTextRole as String,
                        withSubstring: body,
                        underIdentifier: "message-list",
                        timeout: TestTimeout.event
                    )

                    _ = try await bobREPL.waitForOutput(containing: body, timeout: TestTimeout.event)
                }
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `participant sidebar lists current occupants`() async throws {
            let bobProfile = "inttest-ui-bob-\(UUID().uuidString.prefix(8))"
            try await UISeededApp.withSeededApp { app in
                let roomJID = try await Self.joinAndUnlockRoom(app)

                // Sidebar is hidden by default — toggle it on.
                try await app.click(identifier: "toggle-participant-sidebar")
                try await app.waitForElement(identifier: "participant-sidebar", timeout: TestTimeout.uiElement)

                try await app.waitForDescendant(
                    role: kAXStaticTextRole as String,
                    withSubstring: "alice",
                    underIdentifier: "participant-sidebar"
                )

                try await CLIProcess.withProcess(profile: bobProfile) { bobCLI in
                    let bobREPL = try await REPLSession.start(cli: bobCLI, credentials: TestCredentials.bob)
                    await bobCLI.addCleanup { await bobREPL.terminate() }

                    try await bobREPL.send("/join \(roomJID)")
                    _ = try await bobREPL.waitForOutput(containing: "Joined", timeout: TestTimeout.connect)

                    try await app.waitForDescendant(
                        role: kAXStaticTextRole as String,
                        withSubstring: "bob",
                        underIdentifier: "participant-sidebar",
                        timeout: TestTimeout.event
                    )
                }
            }
        }

        // MARK: - Helpers

        /// Joins a fresh room and submits the auto-opened config sheet so
        /// the room is unlocked. Returns the room JID for the test body.
        @MainActor private static func joinAndUnlockRoom(_ app: AppAccessor) async throws -> String {
            let roomJID = "inttest-ui-\(UUID().uuidString.prefix(8))@\(TestCredentials.mucService)"

            try await app.waitForContactRow(TestCredentials.bob)

            try await app.waitForElement(identifier: "join-room-toolbar-button")
            try await app.click(identifier: "join-room-toolbar-button")
            try await app.waitForElement(identifier: "room-jid-field", timeout: TestTimeout.uiElement)
            try await app.type(roomJID, intoIdentifier: "room-jid-field")
            try await app.type("alice", intoIdentifier: "room-nickname-field")
            try await app.click(identifier: "join-room-button")

            // RoomJoinDialog.onJoin opens the chat window; message-field is
            // the most reliable frontmost-chat marker (the participant
            // sidebar is hidden by default).
            try await app.waitForElement(identifier: "message-field", timeout: TestTimeout.connect)

            // The room-config sheet auto-opens on the contact-list window
            // (RoomRowWithMenu.onAppear/onChange). The chat window is now
            // key, so kAXPressAction on the sheet may be silently dropped.
            // Bring the contact-list window forward first.
            try await app.activateWindow(named: "Contacts")
            try await app.waitForElement(identifier: "room-config-save", timeout: TestTimeout.uiElement)
            try await app.click(identifier: "room-config-save")

            // Bring the chat window back to key for the test body.
            try await app.activateWindow(named: roomJID)
            return roomJID
        }
    }
}
