import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeTestModuleContext() -> ModuleContext {
    ModuleContext(
        sendStanza: { _ in },
        sendIQ: { _ in nil },
        emitEvent: { _ in },
        generateID: { "test-1" },
        connectedJID: { FullJID.parse("user@example.com/res") },
        domain: "example.com"
    )
}

// MARK: - Tests

enum ISRTests {
    struct ISRTokenParsing {
        @Test
        func `SM enabled response stores ISR token`() {
            let sm = StreamManagementModule()
            sm.setUp(makeTestModuleContext())

            var enabled = XMLElement(
                name: "enabled",
                namespace: XMPPNamespaces.sm,
                attributes: ["id": "sm-session-1"]
            )
            enabled.addChild(XMLElement(
                name: "isr-enabled",
                namespace: XMPPNamespaces.isr,
                attributes: ["token": "secret-token-123", "mechanism": "HT-SHA-256-ENDP"]
            ))

            sm.processInlineEnabled(enabled)

            #expect(sm.isResumable)
            #expect(sm.hasISRToken)
            #expect(sm.isrToken == "secret-token-123")

            let resume = sm.resumeState
            #expect(resume?.isrToken == "secret-token-123")
            #expect(resume?.isrMechanism == "HT-SHA-256-ENDP")
        }

        @Test
        func `SM enabled without ISR has no token`() {
            let sm = StreamManagementModule()
            sm.setUp(makeTestModuleContext())

            let enabled = XMLElement(
                name: "enabled",
                namespace: XMPPNamespaces.sm,
                attributes: ["id": "sm-session-1"]
            )

            sm.processInlineEnabled(enabled)

            #expect(sm.isResumable)
            #expect(!sm.hasISRToken)
            #expect(sm.isrToken == nil)
        }
    }

    struct ISRTokenUpdate {
        @Test
        func `updateISRToken stores new token`() {
            let sm = StreamManagementModule()
            #expect(sm.isrToken == nil)

            sm.updateISRToken("new-token")
            #expect(sm.isrToken == "new-token")
        }

        @Test
        func `resetResumption clears ISR token`() {
            let sm = StreamManagementModule()
            sm.setUp(makeTestModuleContext())

            var enabled = XMLElement(
                name: "enabled",
                namespace: XMPPNamespaces.sm,
                attributes: ["id": "sm-1"]
            )
            enabled.addChild(XMLElement(
                name: "isr-enabled",
                namespace: XMPPNamespaces.isr,
                attributes: ["token": "my-token"]
            ))
            sm.processInlineEnabled(enabled)

            #expect(sm.hasISRToken)

            sm.resetResumption()

            #expect(!sm.hasISRToken)
            #expect(sm.isrToken == nil)
            #expect(!sm.isResumable)
        }
    }

    struct ISRStateRestore {
        @Test
        func `ISR token survives state snapshot and restore`() {
            let sm = StreamManagementModule()
            sm.setUp(makeTestModuleContext())

            var enabled = XMLElement(
                name: "enabled",
                namespace: XMPPNamespaces.sm,
                attributes: ["id": "sm-1"]
            )
            enabled.addChild(XMLElement(
                name: "isr-enabled",
                namespace: XMPPNamespaces.isr,
                attributes: ["token": "persistent-token", "mechanism": "HT-SHA-256-ENDP"]
            ))
            sm.processInlineEnabled(enabled)

            // Snapshot state
            let snapshot = sm.resumeState
            #expect(snapshot != nil)
            #expect(snapshot?.isrToken == "persistent-token")
            #expect(snapshot?.isrMechanism == "HT-SHA-256-ENDP")

            // Restore into new module
            let restored = StreamManagementModule(previousState: snapshot)
            #expect(restored.hasISRToken)
            #expect(restored.isrToken == "persistent-token")
        }
    }

    struct ISRAuthenticateBuilder {
        @Test
        func `buildISRAuthenticate produces correct structure`() {
            let smResume = XMLElement(
                name: "resume",
                namespace: XMPPNamespaces.sm,
                attributes: ["previd": "session-42", "h": "100"]
            )
            let auth = buildISRAuthenticate(token: "my-isr-token", smResumeElement: smResume)

            #expect(auth.name == "authenticate")
            #expect(auth.namespace == XMPPNamespaces.sasl2)
            #expect(auth.attribute("mechanism") == "HT-SHA-256-ENDP")

            // initial-response contains base64-encoded token
            let initialResponse = auth.childText(named: "initial-response")
            #expect(initialResponse != nil)

            // inst-resume wraps the SM resume element
            let instResume = auth.child(named: "inst-resume", namespace: XMPPNamespaces.isr)
            #expect(instResume != nil)
            let resume = instResume?.child(named: "resume", namespace: XMPPNamespaces.sm)
            #expect(resume?.attribute("previd") == "session-42")
            #expect(resume?.attribute("h") == "100")
        }
    }
}
