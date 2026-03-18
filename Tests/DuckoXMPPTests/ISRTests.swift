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

    struct Bind2ISRTests {
        @Test
        func `buildBind2Request includes isr-enable when enabled`() {
            let bind = buildBind2Request(enableSM: true, enableISR: true)
            let smEnable = bind.child(named: "enable", namespace: XMPPNamespaces.sm)
            #expect(smEnable != nil)
            let isrEnable = smEnable?.child(named: "isr-enable", namespace: XMPPNamespaces.isr)
            #expect(isrEnable != nil)
            #expect(isrEnable?.attribute("mechanism") == "HT-SHA-256-ENDP")
        }

        @Test
        func `buildBind2Request omits isr-enable when disabled`() {
            let bind = buildBind2Request(enableSM: true, enableISR: false)
            let smEnable = bind.child(named: "enable", namespace: XMPPNamespaces.sm)
            #expect(smEnable != nil)
            let isrEnable = smEnable?.child(named: "isr-enable", namespace: XMPPNamespaces.isr)
            #expect(isrEnable == nil)
        }

        @Test
        func `buildBind2Request omits isr-enable when SM disabled`() {
            let bind = buildBind2Request(enableSM: false, enableISR: true)
            let smEnable = bind.child(named: "enable", namespace: XMPPNamespaces.sm)
            #expect(smEnable == nil)
        }
    }

    struct ISRTokenAcquisition {
        @Test
        func `ISR token acquired via SASL2 Bind 2 inline`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            let sm = StreamManagementModule()
            await client.register(sm)
            await client.addInterceptor(sm)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateSASL2ConnectWithISR(mock)
            try await connectTask.value

            #expect(sm.isResumable)
            #expect(sm.hasISRToken)
            #expect(sm.isrToken == "initial-isr-token")

            await client.disconnect()
        }

        @Test
        func `Bind 2 request includes isr-enable when server supports ISR`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            let sm = StreamManagementModule()
            await client.register(sm)
            await client.addInterceptor(sm)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateSASL2ConnectWithISR(mock)
            try await connectTask.value

            // Verify the authenticate element included isr-enable
            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let authSent = sentStrings.first { $0.contains("urn:xmpp:sasl:2") }
            #expect(authSent?.contains("isr-enable") == true)

            await client.disconnect()
        }
    }

    struct ISRResume {
        @Test
        func `ISR resume success emits streamResumed`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            let sm = StreamManagementModule()
            await client.register(sm)
            await client.addInterceptor(sm)

            // Phase 1: Initial connect to acquire ISR token
            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateSASL2ConnectWithISR(mock)
            try await connectTask.value
            #expect(sm.hasISRToken)

            // Snapshot SM state for reconnect
            let smState = sm.resumeState
            await client.disconnect()

            // Phase 2: Reconnect with ISR token
            let mock2 = MockTransport()
            let client2 = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock2, requireTLS: false
            )
            let sm2 = StreamManagementModule(previousState: smState)
            await client2.register(sm2)
            await client2.addInterceptor(sm2)
            #expect(sm2.hasISRToken)

            let events = Task {
                try await collectEvents(from: client2) {
                    if case .streamResumed = $0 { return true }
                    return false
                }
            }

            let connectTask2 = Task { try await client2.connect(host: "example.com", port: 5222) }
            await simulateISRResumeConnect(mock2)
            try await connectTask2.value

            let collected = try await events.value
            let hasResumed = collected.contains {
                if case .streamResumed = $0 { return true }
                return false
            }
            #expect(hasResumed)

            // Verify ISR authenticate was sent (HT-SHA-256-ENDP)
            let sentData = await mock2.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let isrAuth = sentStrings.first { $0.contains("HT-SHA-256-ENDP") }
            #expect(isrAuth != nil)

            await client2.disconnect()
        }

        @Test
        func `ISR resume success refreshes token`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            let sm = StreamManagementModule()
            await client.register(sm)
            await client.addInterceptor(sm)

            // Phase 1: Acquire initial token
            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateSASL2ConnectWithISR(mock)
            try await connectTask.value
            #expect(sm.isrToken == "initial-isr-token")

            let smState = sm.resumeState
            await client.disconnect()

            // Phase 2: ISR resume — server provides refreshed token
            let mock2 = MockTransport()
            let client2 = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock2, requireTLS: false
            )
            let sm2 = StreamManagementModule(previousState: smState)
            await client2.register(sm2)
            await client2.addInterceptor(sm2)

            let connectTask2 = Task { try await client2.connect(host: "example.com", port: 5222) }
            await simulateISRResumeConnect(mock2)
            try await connectTask2.value

            #expect(sm2.isrToken == "refreshed-token")

            await client2.disconnect()
        }

        @Test
        func `ISR failure falls back to normal SASL2 auth`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            let sm = StreamManagementModule()
            await client.register(sm)
            await client.addInterceptor(sm)

            // Phase 1: Acquire ISR token
            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateSASL2ConnectWithISR(mock)
            try await connectTask.value

            let smState = sm.resumeState
            await client.disconnect()

            // Phase 2: ISR fails, fallback to normal SASL2
            let mock2 = MockTransport()
            let client2 = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock2, requireTLS: false
            )
            let sm2 = StreamManagementModule(previousState: smState)
            await client2.register(sm2)
            await client2.addInterceptor(sm2)

            let events = Task {
                try await collectEvents(from: client2) {
                    if case .connected = $0 { return true }
                    return false
                }
            }

            let connectTask2 = Task { try await client2.connect(host: "example.com", port: 5222) }
            await simulateISRFailAndFallback(mock2)
            try await connectTask2.value

            let collected = try await events.value
            let hasConnected = collected.contains {
                if case .connected = $0 { return true }
                return false
            }
            #expect(hasConnected)

            // ISR token should be cleared after failure
            #expect(!sm2.hasISRToken)

            await client2.disconnect()
        }

        @Test
        func `ISR not attempted without token`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            let sm = StreamManagementModule()
            await client.register(sm)
            await client.addInterceptor(sm)
            #expect(!sm.hasISRToken)

            // Connect with ISR-enabled features but no prior token
            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateSASL2ConnectWithISR(mock)
            try await connectTask.value

            // Should have done normal SASL2 auth, not ISR
            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }

            // ISR auth uses mechanism="HT-SHA-256-ENDP" on the <authenticate> element itself
            let isrAuth = sentStrings.first { $0.contains("mechanism=\"HT-SHA-256-ENDP\"") && $0.contains("inst-resume") }
            #expect(isrAuth == nil)

            // Normal SASL2 authenticate should have been sent with PLAIN
            let sasl2Auth = sentStrings.first { $0.contains("mechanism=\"PLAIN\"") }
            #expect(sasl2Auth != nil)

            await client.disconnect()
        }

        @Test
        func `ISR not attempted when server lacks ISR support`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            // Create SM with a previous ISR token
            let previousState = try SMResumeState(
                resumptionId: "sm-1",
                incomingCounter: 0,
                outgoingCounter: 0,
                outgoingQueue: [],
                connectedJID: #require(FullJID.parse("user@example.com/ducko")),
                location: nil,
                isrToken: "stale-token",
                isrMechanism: "HT-SHA-256-ENDP"
            )
            let sm = StreamManagementModule(previousState: previousState)
            await client.register(sm)
            await client.addInterceptor(sm)
            #expect(sm.hasISRToken)

            // Server features do NOT include ISR — use standard SASL2
            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateSASL2Connect(mock)
            try await connectTask.value

            // No ISR authenticate should have been sent
            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let isrAuth = sentStrings.first { $0.contains("HT-SHA-256-ENDP") }
            #expect(isrAuth == nil)

            await client.disconnect()
        }
    }
}
