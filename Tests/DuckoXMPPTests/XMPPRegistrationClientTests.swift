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

    @Test
    func `Retrieving a form for a domain with no A-label fails closed`() async {
        // The IDNA guard throws before any network I/O (a space is not LDH, so no A-label).
        await #expect(throws: XMPPRegistrationClient.RegistrationClientError.self) {
            _ = try await XMPPRegistrationClient.retrieveForm(domain: "bad domain.example")
        }
    }
}
