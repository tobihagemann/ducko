import DuckoTestSupport
import Testing
@testable import DuckoXMPP

struct XMPPRegistrationClientTests {
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
