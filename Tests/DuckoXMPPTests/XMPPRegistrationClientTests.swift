import DuckoTestSupport
import Testing
@testable import DuckoXMPP

struct XMPPRegistrationClientTests {
    @Test(arguments: [false, true])
    func `pre-auth operation closes its transport after success`(register: Bool) async throws {
        let transport = RegistrationTransport()
        let task = registrationTask(transport: transport, register: register)
        do {
            try await negotiate(transport)
            let request = try await awaitOutgoingIQ(on: transport.mock, type: register ? .set : .get, namespace: XMPPNamespaces.register) {
                $0.contains("id=\"reg1\"")
            }
            if register {
                #expect(request.xml.contains("<username>new-user</username>"))
            }
            await transport.mock.simulateReceive("<iq type='result' id='\(request.id)'><query xmlns='jabber:iq:register'><username/><password/></query></iq>")
        } catch {
            task.cancel()
            await transport.disconnect()
            _ = await task.result
            throw error
        }
        let form = try await task.value
        if !register {
            #expect(form?.hasUsername == true)
            #expect(form?.hasPassword == true)
        }
        #expect(await transport.disconnectCalls == 1)
        #expect(await transport.mock.isConnected == false)
        #expect(await transport.mock.tlsServerName == "example.com")
    }

    @Test(arguments: [false, true])
    func `partial connect failure releases the registration transport`(register: Bool) async {
        let transport = RegistrationTransport(failConnect: true)
        let task = registrationTask(transport: transport, register: register)
        await #expect(throws: XMPPClientError.self) { try await task.value }
        #expect(await transport.disconnectCalls == 1)
        #expect(await transport.mock.isConnected == false)
    }

    @Test(arguments: [false, true])
    func `invalid registration domain never opens a transport`(register: Bool) async {
        let transport = RegistrationTransport()
        let task = registrationTask(transport: transport, register: register, domain: "bad domain.example")
        await #expect(throws: XMPPRegistrationClient.RegistrationClientError.self) { try await task.value }
        #expect(await transport.mock.connectedHost == nil)
        #expect(await transport.disconnectCalls == 0)
    }

    @Test(arguments: [false, true], [false, true])
    func `registration cancellation releases the transport during negotiation or response wait`(register: Bool, afterTLS: Bool) async throws {
        let transport = RegistrationTransport()
        let task = registrationTask(transport: transport, register: register)
        do {
            if afterTLS {
                try await negotiate(transport)
                _ = try await awaitOutgoingIQ(on: transport.mock, type: register ? .set : .get, namespace: XMPPNamespaces.register) {
                    $0.contains("id=\"reg1\"")
                }
            } else {
                try await transport.awaitSent { $0.hasPrefix("<?xml") || $0.hasPrefix("<stream:stream") }
            }
        } catch {
            task.cancel()
            await transport.disconnect()
            _ = await task.result
            throw error
        }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(await transport.disconnectCalls == 1)
        #expect(await transport.mock.isConnected == false)
    }

    @Test(arguments: [false, true])
    func `registration rejection preserves operation-specific errors and closes transport`(register: Bool) async throws {
        let transport = RegistrationTransport()
        let task = registrationTask(transport: transport, register: register)
        do {
            try await negotiate(transport)
            let request = try await awaitOutgoingIQ(on: transport.mock, type: register ? .set : .get, namespace: XMPPNamespaces.register) {
                $0.contains("id=\"reg1\"")
            }
            await transport.mock.simulateReceive("<iq type='error' id='\(request.id)'><error type='cancel'><conflict xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
        } catch {
            task.cancel()
            await transport.disconnect()
            _ = await task.result
            throw error
        }
        let error = await #expect(throws: XMPPRegistrationClient.RegistrationClientError.self) { try await task.value }
        if register {
            guard case let .registrationFailed(text) = error else {
                Issue.record("Expected registration rejection")
                return
            }
            #expect(text == "The username is already taken")
        } else {
            guard case .unexpectedResponse = error else {
                Issue.record("Expected invalid form response")
                return
            }
        }
        #expect(await transport.disconnectCalls == 1)
        #expect(await transport.mock.isConnected == false)
    }

    private func registrationTask(
        transport: RegistrationTransport, register: Bool, domain: String = "example.com"
    ) -> Task<RegistrationModule.RegistrationForm?, any Error> {
        Task {
            if register {
                try await XMPPRegistrationClient.register(domain: domain, username: "new-user", password: "secret", host: "example.com", transport: transport)
                return nil
            }
            return try await XMPPRegistrationClient.retrieveForm(domain: domain, host: "example.com", transport: transport)
        }
    }

    private func negotiate(_ transport: RegistrationTransport) async throws {
        try await transport.awaitSent { $0.hasPrefix("<?xml") || $0.hasPrefix("<stream:stream") }
        await transport.mock.simulateReceive(testServerStreamOpen)
        await transport.mock.simulateReceive(testFeaturesWithTLS)
        try await transport.awaitSent { $0.contains("<starttls") }
        // Clear before triggering the next phase so its stream opening cannot match the first one.
        await transport.mock.clearSentBytes()
        await transport.mock.simulateReceive(testProceed)
        try await transport.awaitSent { $0.hasPrefix("<?xml") || $0.hasPrefix("<stream:stream") }
        await transport.mock.simulateReceive(testServerStreamOpen)
        await transport.mock.simulateReceive(testFeaturesNoTLS)
    }

    @Test
    func `RegistrationClientError cases`() {
        let err1 = XMPPRegistrationClient.RegistrationClientError.connectionFailed("timeout")
        let err2 = XMPPRegistrationClient.RegistrationClientError.tlsNegotiationFailed
        let err3 = XMPPRegistrationClient.RegistrationClientError.registrationNotSupported
        let err4 = XMPPRegistrationClient.RegistrationClientError.registrationFailed("conflict")
        let err5 = XMPPRegistrationClient.RegistrationClientError.unexpectedResponse

        switch err1 {
        case let .connectionFailed(msg): #expect(msg == "timeout")
        case .tlsNegotiationFailed, .registrationNotSupported, .registrationFailed, .unexpectedResponse:
            Issue.record("Wrong case")
        }

        switch err2 {
        case .tlsNegotiationFailed: break
        case .connectionFailed, .registrationNotSupported, .registrationFailed, .unexpectedResponse:
            Issue.record("Wrong case")
        }

        switch err3 {
        case .registrationNotSupported: break
        case .connectionFailed, .tlsNegotiationFailed, .registrationFailed, .unexpectedResponse:
            Issue.record("Wrong case")
        }

        switch err4 {
        case let .registrationFailed(msg): #expect(msg == "conflict")
        case .connectionFailed, .tlsNegotiationFailed, .registrationNotSupported, .unexpectedResponse:
            Issue.record("Wrong case")
        }

        switch err5 {
        case .unexpectedResponse: break
        case .connectionFailed, .tlsNegotiationFailed, .registrationNotSupported, .registrationFailed:
            Issue.record("Wrong case")
        }
    }

    @Test(arguments: [
        (XMPPStanzaError?.none, "The server gave no reason"),
        (XMPPStanzaError(errorType: .cancel, condition: .conflict), "The username is already taken"),
        (XMPPStanzaError(errorType: .cancel, condition: .conflict, text: "Name reserved"), "Name reserved"),
        (XMPPStanzaError(errorType: .cancel, condition: .conflict, text: "  "), "The username is already taken"),
        (XMPPStanzaError(errorType: .modify, condition: .notAcceptable), "The recipient does not accept this request")
    ])
    func `Registration failure text reads the stanza error`(error: XMPPStanzaError?, expected: String) {
        #expect(XMPPRegistrationClient.registrationFailureText(error) == expected)
    }

    @Test
    func `Registration STARTTLS reopens the stream after the upgrade`() async throws {
        let mock = MockTransport()
        let connection = XMPPConnection(transport: mock)
        let negotiation = try await startNegotiation(on: connection)

        await mock.waitForSent(count: 1) // stream opening
        await mock.simulateReceive(testServerStreamOpen)
        await mock.simulateReceive(testFeaturesWithTLS)
        await mock.waitForSent(count: 2) // starttls element
        await mock.simulateReceive(testProceed)
        await mock.waitForSent(count: 3) // post-TLS stream opening
        await mock.simulateReceive(testServerStreamOpen)
        await mock.simulateReceive(testFeaturesNoTLS)

        try await negotiation.value
        let isTLS = await mock.isTLSUpgraded
        #expect(isTLS)

        await connection.disconnect()
    }

    @Test
    func `Registration treats a proceed without the TLS namespace as a refusal`() async throws {
        let mock = MockTransport()
        let connection = XMPPConnection(transport: mock)
        let negotiation = try await startNegotiation(on: connection)

        await mock.waitForSent(count: 1) // stream opening
        await mock.simulateReceive(testServerStreamOpen)
        await mock.simulateReceive(testFeaturesWithTLS)
        await mock.waitForSent(count: 2) // starttls element
        await mock.simulateReceive("<proceed/>")

        let error = await #expect(throws: XMPPRegistrationClient.RegistrationClientError.self) {
            try await negotiation.value
        }
        guard case .tlsNegotiationFailed = error else {
            Issue.record("Expected tlsNegotiationFailed, got \(String(describing: error))")
            return
        }
        let isTLS = await mock.isTLSUpgraded
        #expect(!isTLS)

        await connection.disconnect()
    }

    private func startNegotiation(on connection: XMPPConnection) async throws -> Task<Void, any Error> {
        try await connection.connect(host: "example.com", port: 5222)
        let reader = EventReader(connection.events)
        return Task {
            try await XMPPRegistrationClient.negotiateStream(
                connection: connection, reader: reader, domain: "example.com", serverName: "example.com"
            )
        }
    }

    @Test
    func `Retrieving a form for a domain with no A-label fails closed`() async {
        // The IDNA guard throws before any network I/O (a space is not LDH, so no A-label).
        await #expect(throws: XMPPRegistrationClient.RegistrationClientError.self) {
            _ = try await XMPPRegistrationClient.retrieveForm(domain: "bad domain.example")
        }
    }
}

private actor RegistrationTransport: XMPPTransport {
    nonisolated let mock = MockTransport()
    nonisolated var receivedData: AsyncStream<[UInt8]> {
        mock.receivedData
    }

    private let failConnect: Bool
    private(set) var disconnectCalls = 0

    init(failConnect: Bool = false) {
        self.failConnect = failConnect
    }

    func connect(host: String, port: UInt16) async throws {
        try await mock.connect(host: host, port: port)
        if failConnect { throw XMPPClientError.connectionFailed("fixture") }
    }

    func connectWithTLS(host: String, port: UInt16, serverName: String) async throws {
        try await mock.connectWithTLS(host: host, port: port, serverName: serverName)
    }

    func stopReceiving() async {
        await mock.stopReceiving()
    }

    func upgradeTLS(serverName: String) async throws -> AsyncStream<[UInt8]> {
        try await mock.upgradeTLS(serverName: serverName)
    }

    func send(_ bytes: [UInt8]) async throws {
        try await mock.send(bytes)
    }

    func disconnect() async {
        disconnectCalls += 1
        await mock.disconnect()
    }

    func awaitSent(matching predicate: @escaping @Sendable (String) -> Bool) async throws {
        try await withThrowingTaskGroup(of: String?.self) { group in
            defer { group.cancelAll() }
            group.addTask { await self.mock.waitForSent(matching: predicate) }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw XMPPClientError.timeout
            }
            let result = try await group.next()!
            try Task.checkCancellation()
            guard result != nil else { throw XMPPClientError.timeout }
        }
    }
}
