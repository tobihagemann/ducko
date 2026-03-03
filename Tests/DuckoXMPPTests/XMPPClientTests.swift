import os
import Testing
@testable import DuckoXMPP

// MARK: - Test Helpers

/// Features offering STARTTLS and PLAIN auth.
private let featuresWithTLS = """
<features xmlns='http://etherx.jabber.org/streams'>\
<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>\
<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\
<mechanism>PLAIN</mechanism>\
</mechanisms>\
</features>
"""

/// Post-auth features with bind and session.
private let featuresBindSession = """
<features xmlns='http://etherx.jabber.org/streams'>\
<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>\
<session xmlns='urn:ietf:params:xml:ns:xmpp-session'/>\
</features>
"""

/// Session result.
private let sessionResult = "<iq type='result' id='ducko-2'/>"

/// Simulates a full connect handshake with STARTTLS on the mock transport.
private func simulateTLSConnectFlow(_ mock: MockTransport) async {
    try? await Task.sleep(for: .milliseconds(50))

    // 1. Initial stream open → features with TLS
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(featuresWithTLS)
    try? await Task.sleep(for: .milliseconds(50))

    // 2. TLS proceed
    await mock.simulateReceive("<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
    try? await Task.sleep(for: .milliseconds(50))

    // 3. Post-TLS stream → features with auth
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testFeaturesNoTLS)
    try? await Task.sleep(for: .milliseconds(50))

    // 4. Auth success
    await mock.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
    try? await Task.sleep(for: .milliseconds(50))

    // 5. Post-auth stream → features with bind
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testFeaturesBind)
    try? await Task.sleep(for: .milliseconds(50))

    // 6. Bind result
    await mock.simulateReceive(testBindResult)
}

/// Simulates a connect handshake with session establishment.
private func simulateSessionConnectFlow(_ mock: MockTransport) async {
    try? await Task.sleep(for: .milliseconds(50))

    // 1. Stream open → features without TLS
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testFeaturesNoTLS)
    try? await Task.sleep(for: .milliseconds(50))

    // 2. Auth success
    await mock.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
    try? await Task.sleep(for: .milliseconds(50))

    // 3. Post-auth stream → features with bind + session
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(featuresBindSession)
    try? await Task.sleep(for: .milliseconds(50))

    // 4. Bind result
    await mock.simulateReceive(testBindResult)
    try? await Task.sleep(for: .milliseconds(50))

    // 5. Session result
    await mock.simulateReceive(sessionResult)
}

// MARK: - Tests

enum XMPPClientTests {
    struct ConnectFlow {
        @Test
        func `Full connect with STARTTLS and PLAIN auth`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateTLSConnectFlow(mock)
            try await connectTask.value

            let isTLS = await mock.isTLSUpgraded
            #expect(isTLS)

            await client.disconnect()
        }

        @Test
        func `Connect without TLS`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let isTLS = await mock.isTLSUpgraded
            #expect(!isTLS)

            await client.disconnect()
        }

        @Test
        func `Connect with legacy session establishment`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateSessionConnectFlow(mock)
            try await connectTask.value

            await client.disconnect()
        }

        @Test
        func `Connected event includes full JID`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .connected = event { return true }
                    return false
                }
            }

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let events = try await eventsTask.value
            guard case let .connected(jid) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected connected event")
            }
            #expect(jid.bareJID.localPart == "user")
            #expect(jid.bareJID.domainPart == "example.com")
            #expect(jid.resourcePart == "ducko")

            await client.disconnect()
        }
    }

    struct AuthFailure {
        @Test
        func `Auth failure emits event and throws`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "wrong"),
                transport: mock
            )

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .authenticationFailed = event { return true }
                    return false
                }
            }

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }

            try? await Task.sleep(for: .milliseconds(50))
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(testFeaturesNoTLS)
            try? await Task.sleep(for: .milliseconds(50))
            await mock.simulateReceive(
                "<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><not-authorized/></failure>"
            )

            do {
                try await connectTask.value
                throw XMPPClientError.unexpectedStreamState("Should have thrown")
            } catch is XMPPClientError {
                // Expected
            }

            let events = try await eventsTask.value
            guard case .authenticationFailed = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected authenticationFailed event")
            }

            await client.disconnect()
        }
    }

    struct IQTracking {
        @Test
        func `sendIQ returns result child element`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let iqTask = Task {
                var iq = XMPPIQ(type: .get, id: "test-iq-1")
                let query = XMLElement(name: "query", namespace: "jabber:iq:roster")
                iq.element.addChild(query)
                return try await client.sendIQ(iq)
            }

            try? await Task.sleep(for: .milliseconds(100))
            await mock.simulateReceive(
                "<iq type='result' id='test-iq-1'><query xmlns='jabber:iq:roster'><item jid='contact@example.com'/></query></iq>"
            )

            let result = try await iqTask.value
            #expect(result?.name == "query")

            await client.disconnect()
        }

        @Test
        func `sendIQ returns nil for error response`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let iqTask = Task {
                let iq = XMPPIQ(type: .get, id: "test-iq-2")
                return try await client.sendIQ(iq)
            }

            try? await Task.sleep(for: .milliseconds(100))
            await mock.simulateReceive(
                "<iq type='error' id='test-iq-2'><error type='cancel'><item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
            )

            let result = try await iqTask.value
            #expect(result == nil)

            await client.disconnect()
        }

        @Test
        func `Disconnect cancels pending IQs`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let iqTask = Task {
                let iq = XMPPIQ(type: .get, id: "test-iq-3")
                return try await client.sendIQ(iq)
            }

            try? await Task.sleep(for: .milliseconds(100))
            await client.disconnect()

            do {
                _ = try await iqTask.value
                throw XMPPClientError.unexpectedStreamState("Should have thrown")
            } catch is XMPPClientError {
                // Expected: notConnected
            }
        }
    }

    struct StanzaDispatch {
        @Test
        func `Chat message dispatches to ChatModule`() async throws {
            let mock = MockTransport()
            let chatModule = ChatModule()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )
            await client.register(chatModule)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .messageReceived = event { return true }
                    return false
                }
            }

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            await mock.simulateReceive(
                "<message type='chat' from='contact@example.com/res'><body>Hello!</body></message>"
            )

            let events = try await eventsTask.value
            guard case let .messageReceived(message) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected messageReceived event")
            }
            #expect(message.body == "Hello!")
            #expect(message.from?.description == "contact@example.com/res")

            await client.disconnect()
        }

        @Test
        func `Presence stanza emits presenceReceived event`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .presenceReceived = event { return true }
                    return false
                }
            }

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            await mock.simulateReceive(
                "<presence from='contact@example.com/res'><show>away</show></presence>"
            )

            let events = try await eventsTask.value
            guard case let .presenceReceived(presence) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected presenceReceived event")
            }
            #expect(presence.show == .away)

            await client.disconnect()
        }

        @Test
        func `IQ stanza emits iqReceived event`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .iqReceived = event { return true }
                    return false
                }
            }

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            await mock.simulateReceive(
                "<iq type='get' from='example.com' id='server-1'><query xmlns='jabber:iq:version'/></iq>"
            )

            let events = try await eventsTask.value
            guard case let .iqReceived(iq) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected iqReceived event")
            }
            #expect(iq.isGet)
            #expect(iq.id == "server-1")

            await client.disconnect()
        }
    }

    struct Disconnection {
        @Test
        func `Stream close emits disconnected event`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .disconnected = event { return true }
                    return false
                }
            }

            try? await Task.sleep(for: .milliseconds(50))
            await mock.simulateReceive("</stream:stream>")
            try? await Task.sleep(for: .milliseconds(50))

            let events = try await eventsTask.value
            guard case let .disconnected(reason) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected disconnected event")
            }
            if case .streamError = reason {
                // Expected
            } else {
                throw XMPPClientError.unexpectedStreamState("Expected streamError reason, got \(reason)")
            }
        }
    }

    struct Builder {
        @Test
        func `Builder creates client with modules`() async {
            let mock = MockTransport()
            var builder = XMPPClientBuilder(domain: "example.com", username: "user", password: "pass")
            builder.withTransport(mock)
            builder.withModule(ChatModule())
            let client = await builder.build()

            let chatModule = await client.module(ofType: ChatModule.self)
            #expect(chatModule != nil)

            await client.disconnect()
        }
    }

    struct IDGeneration {
        @Test
        func `IDs are sequential`() async {
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass")
            )
            let id1 = client.generateID()
            let id2 = client.generateID()
            #expect(id1 == "ducko-1")
            #expect(id2 == "ducko-2")

            await client.disconnect()
        }
    }

    // MARK: - IQ Timeout

    struct IQTimeoutTests {
        @Test
        func `IQ times out when no response arrives`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let iqTask = Task {
                let iq = XMPPIQ(type: .get, id: "test-timeout")
                return try await client.sendIQ(iq, timeout: .milliseconds(200))
            }

            // Don't respond — let the timeout expire
            do {
                _ = try await iqTask.value
                throw XMPPClientError.unexpectedStreamState("Should have thrown timeout")
            } catch let error as XMPPClientError {
                guard case .timeout = error else {
                    throw XMPPClientError.unexpectedStreamState("Expected timeout, got \(error)")
                }
            }

            await client.disconnect()
        }

        @Test
        func `IQ from wrong JID does not match pending request`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let iqTask = Task {
                var iq = XMPPIQ(type: .get, id: "test-jid-match")
                iq.to = .bare(BareJID(localPart: "alice", domainPart: "example.com")!)
                return try await client.sendIQ(iq, timeout: .seconds(5))
            }

            try? await Task.sleep(for: .milliseconds(100))

            // Response from wrong JID — should NOT satisfy the pending IQ
            await mock.simulateReceive(
                "<iq type='result' id='test-jid-match' from='eve@evil.com'><wrong/></iq>"
            )
            try? await Task.sleep(for: .milliseconds(100))

            // Response from correct JID — should satisfy the pending IQ
            await mock.simulateReceive(
                "<iq type='result' id='test-jid-match' from='alice@example.com'><query/></iq>"
            )

            let result = try await iqTask.value
            #expect(result?.name == "query")

            await client.disconnect()
        }

        @Test
        func `Server-directed IQ accepts response with no from`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let iqTask = Task {
                // No `to` — server-directed IQ
                let iq = XMPPIQ(type: .get, id: "test-server-iq")
                return try await client.sendIQ(iq, timeout: .seconds(5))
            }

            try? await Task.sleep(for: .milliseconds(100))
            await mock.simulateReceive(
                "<iq type='result' id='test-server-iq'><query xmlns='jabber:iq:roster'/></iq>"
            )

            let result = try await iqTask.value
            #expect(result?.name == "query")

            await client.disconnect()
        }
    }

    // MARK: - Stanza Interceptor

    struct StanzaInterceptorTests {
        @Test
        func `Consuming interceptor blocks message dispatch`() async throws {
            let mock = MockTransport()
            let interceptor = MessageConsumingInterceptor()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )
            await client.addInterceptor(interceptor)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            // Collect events until a presence arrives
            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .presenceReceived = event { return true }
                    return false
                }
            }

            // Send a message (should be consumed) then a presence (should pass through)
            await mock.simulateReceive(
                "<message type='chat' from='contact@example.com/res'><body>Blocked!</body></message>"
            )
            await mock.simulateReceive(
                "<presence from='contact@example.com/res'/>"
            )

            let events = try await eventsTask.value
            // Should have presenceReceived but NOT messageReceived
            let hasMessage = events.contains { if case .messageReceived = $0 { return true }; return false }
            let hasPresence = events.contains { if case .presenceReceived = $0 { return true }; return false }
            #expect(!hasMessage)
            #expect(hasPresence)

            await client.disconnect()
        }

        @Test
        func `Non-consuming interceptor allows normal dispatch`() async throws {
            let mock = MockTransport()
            let interceptor = PassthroughInterceptor()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )
            await client.addInterceptor(interceptor)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .messageReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(
                "<message type='chat' from='contact@example.com/res'><body>Allowed!</body></message>"
            )

            let events = try await eventsTask.value
            guard case let .messageReceived(message) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected messageReceived event")
            }
            #expect(message.body == "Allowed!")

            await client.disconnect()
        }
    }

    // MARK: - Module Features

    struct ModuleFeatureTests {
        @Test
        func `availableFeatures aggregates from registered modules`() async {
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass")
            )
            await client.register(FeatureModuleA())
            await client.register(FeatureModuleB())

            let features = await client.availableFeatures
            #expect(features.count == 3)
            #expect(features.contains("urn:xmpp:feature-a1"))
            #expect(features.contains("urn:xmpp:feature-a2"))
            #expect(features.contains("urn:xmpp:feature-b1"))

            await client.disconnect()
        }

        @Test
        func `Module with no features returns empty set`() async {
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass")
            )
            await client.register(ChatModule())

            let features = await client.availableFeatures
            #expect(features.isEmpty)

            await client.disconnect()
        }
    }

    // MARK: - Module Disconnect Hook

    struct DisconnectHookTests {
        @Test
        func `handleDisconnect is called on clean disconnect`() async throws {
            let mock = MockTransport()
            let module = DisconnectTrackingModule()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )
            await client.register(module)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            #expect(!module.wasDisconnected)
            await client.disconnect()
            #expect(module.wasDisconnected)
        }
    }
}

// MARK: - Test Mocks

/// Interceptor that consumes all `<message>` stanzas, passes everything else through.
private final class MessageConsumingInterceptor: StanzaInterceptor {
    func processIncoming(_ element: XMLElement) -> Bool {
        element.name == "message"
    }

    func processOutgoing(_ element: XMLElement) {}
}

/// Interceptor that never consumes anything.
private final class PassthroughInterceptor: StanzaInterceptor {
    func processIncoming(_ element: XMLElement) -> Bool {
        false
    }

    func processOutgoing(_ element: XMLElement) {}
}

/// Module that declares features for testing `availableFeatures` aggregation.
private final class FeatureModuleA: XMPPModule {
    var features: [String] {
        ["urn:xmpp:feature-a1", "urn:xmpp:feature-a2"]
    }

    func setUp(_ context: ModuleContext) {}
}

/// Module that declares features for testing `availableFeatures` aggregation.
private final class FeatureModuleB: XMPPModule {
    var features: [String] {
        ["urn:xmpp:feature-b1"]
    }

    func setUp(_ context: ModuleContext) {}
}

/// Module that tracks whether `handleDisconnect()` was called.
private final class DisconnectTrackingModule: XMPPModule, @unchecked Sendable {
    private let _disconnected = OSAllocatedUnfairLock(initialState: false)

    var wasDisconnected: Bool {
        _disconnected.withLock { $0 }
    }

    func setUp(_ context: ModuleContext) {}

    func handleDisconnect() async {
        _disconnected.withLock { $0 = true }
    }
}
