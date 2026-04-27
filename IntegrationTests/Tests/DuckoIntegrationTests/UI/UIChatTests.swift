import ApplicationServices
import Carbon.HIToolbox
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.UILayer {
    struct UIChatTests {
        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `double-clicking a contact opens the chat window`() async throws {
            try await UISeededApp.withSeededApp { app in
                let bob = TestCredentials.bob
                try await app.waitForElement(identifier: "contact-row-\(bob.jid)")
                try await app.doubleClick(identifier: "contact-row-\(bob.jid)")
                try await app.waitForElement(identifier: "message-field", timeout: TestTimeout.uiElement)
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `sending a message renders it in the message list`() async throws {
            try await UISeededApp.withSeededApp { app in
                let bob = TestCredentials.bob
                try await app.doubleClick(identifier: "contact-row-\(bob.jid)")
                try await app.waitForElement(identifier: "message-field", timeout: TestTimeout.uiElement)

                let body = "UI test \(UUID().uuidString)"
                try await app.type(body, intoIdentifier: "message-field")
                try await app.pressReturn(intoIdentifier: "message-field")

                try await app.waitForElement(identifier: "message-list", timeout: TestTimeout.uiElement)
                try await app.waitForDescendant(
                    role: kAXStaticTextRole as String,
                    withSubstring: body,
                    underIdentifier: "message-list"
                )
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `incoming messages from a CLI bob appear in the chat window`() async throws {
            let bobProfile = "inttest-ui-bob-\(UUID().uuidString.prefix(8))"
            try await UISeededApp.withSeededApp { app in
                let bob = TestCredentials.bob
                try await app.doubleClick(identifier: "contact-row-\(bob.jid)")
                try await app.waitForElement(identifier: "message-field", timeout: TestTimeout.uiElement)

                try await CLIProcess.withProcess(profile: bobProfile) { bobCLI in
                    let bobREPL = try await REPLSession.start(cli: bobCLI, credentials: bob)
                    await bobCLI.addCleanup { await bobREPL.terminate() }

                    let body = "ui-recv-\(UUID().uuidString.prefix(8))"
                    try await bobREPL.send("send \(TestCredentials.alice.jid) \(body)")

                    try await app.waitForElement(identifier: "message-list", timeout: TestTimeout.event)
                    try await app.waitForDescendant(
                        role: kAXStaticTextRole as String,
                        withSubstring: body,
                        underIdentifier: "message-list",
                        timeout: TestTimeout.event
                    )
                }
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `bob composing notification surfaces a typing indicator`() async throws {
            try await UISeededApp.withSeededApp { app in
                let bob = TestCredentials.bob
                let alice = TestCredentials.alice

                try await app.doubleClick(identifier: "contact-row-\(bob.jid)")
                try await app.waitForElement(identifier: "message-field", timeout: TestTimeout.uiElement)

                let aliceJID = try #require(BareJID.parse(alice.jid))
                let bobJID = try #require(BareJID.parse(bob.jid))
                let bobUsername = try #require(bobJID.localPart)

                var builder = XMPPClientBuilder(
                    domain: bobJID.domainPart,
                    username: bobUsername,
                    password: bob.password
                )
                builder.withPreferredResource("inttest-ui-typing")
                builder.withModule(ChatModule())
                builder.withModule(ChatStatesModule())
                let client = await builder.build()

                // Register disconnect immediately so a thrown connect()
                // still tears down.
                await app.addCleanup({ await client.disconnect() }, phase: .inApp)

                try await client.connect()
                try await TestHarness.waitForRawEvent(in: client.events, timeout: TestTimeout.connect) { event in
                    if case .connected = event { return true }
                    return false
                }

                let chatStates = try #require(await client.module(ofType: ChatStatesModule.self))
                try await chatStates.sendChatState(.composing, to: .bare(aliceJID))

                try await app.waitForElement(
                    identifier: "typing-indicator",
                    timeout: TestTimeout.event
                )

                try await chatStates.sendChatState(.active, to: .bare(aliceJID))

                // Assert dismissal — the indicator must actually disappear,
                // not merely "may have disappeared by the time we checked".
                try await app.waitForAbsence(
                    identifier: "typing-indicator",
                    timeout: TestTimeout.event
                )
            }
        }

        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && CLIProcess.binaryExists,
            "Ducko.app missing, AX trust not granted, or DuckoCLI binary missing"
        ))
        @MainActor func `correcting a sent message updates its body`() async throws {
            try await UISeededApp.withSeededApp { app in
                let bob = TestCredentials.bob
                try await app.doubleClick(identifier: "contact-row-\(bob.jid)")
                try await app.waitForElement(identifier: "message-field", timeout: TestTimeout.uiElement)

                let body = "ui-edit-\(UUID().uuidString.prefix(8))"
                try await app.type(body, intoIdentifier: "message-field")
                try await app.pressReturn(intoIdentifier: "message-field")

                try await app.waitForElement(identifier: "message-list", timeout: TestTimeout.uiElement)
                try await app.waitForDescendant(
                    role: kAXStaticTextRole as String,
                    withSubstring: body,
                    underIdentifier: "message-list"
                )

                let bubbleIdentifier = try await app.lastIdentifier(
                    matchingPrefix: "message-bubble-",
                    underIdentifier: "message-list"
                )
                let resolved = try #require(bubbleIdentifier)
                let messageID = String(resolved.dropFirst("message-bubble-".count))

                try await app.rightClick(identifier: "message-bubble-\(messageID)")
                try await app.contextMenuItem(identifier: "edit-message-menu-item")

                // The edit field is pre-populated with the original body
                // (MessageInputView.onChange(of: editingMessage?.id) sets
                // text = editing.body). Clear it first so the typed value
                // is deterministic regardless of whether AppAccessor.type
                // takes the kAXValueAttribute SET path (replace) or the
                // keystroke fallback (append). Without the clear, the
                // append path would leave the field as
                // "<body><body> (edited)" — the assertion's substring
                // match would still pass while the actual sent message
                // body was wrong.
                try await app.waitForElement(identifier: "message-field", timeout: TestTimeout.uiElement)
                try await app.pressKey(CGKeyCode(kVK_ANSI_A), modifiers: .maskCommand)
                try await app.pressKey(CGKeyCode(kVK_Delete), modifiers: [])

                let editedBody = "\(body) (edited)"
                try await app.type(editedBody, intoIdentifier: "message-field")
                try await app.pressReturn(intoIdentifier: "message-field")

                try await app.waitForDescendant(
                    role: kAXStaticTextRole as String,
                    withSubstring: editedBody,
                    underIdentifier: "message-list"
                )
            }
        }
    }
}
