import Logging

private let log = Logger(label: "im.ducko.xmpp.registrationclient")

/// Lightweight client for XEP-0077 pre-auth registration.
/// Manages its own connection lifecycle — connect, negotiate TLS, register, disconnect.
public enum XMPPRegistrationClient {
    public enum RegistrationClientError: Error {
        case connectionFailed(String)
        case tlsNegotiationFailed
        case registrationNotSupported
        case registrationFailed(String)
        case unexpectedResponse
    }

    /// Retrieves the registration form from a server without authenticating.
    public static func retrieveForm(
        domain: String,
        host: String? = nil,
        port: UInt16 = 5222
    ) async throws -> RegistrationModule.RegistrationForm {
        let connection = XMPPConnection(transport: POSIXTransport())
        let reader = EventReader(connection.events)

        do {
            if let host {
                try await connection.connect(host: host, port: port)
            } else {
                try await connection.connect(domain: domain)
            }

            try await negotiateStream(connection: connection, reader: reader, domain: domain)

            // Send registration query
            var iq = XMPPIQ(type: .get, id: "reg1")
            let query = XMLElement(name: "query", namespace: XMPPNamespaces.register)
            iq.element.addChild(query)
            try await connection.send(XMPPStreamWriter.stanza(iq.element))

            let response = try await awaitStanza(reader)
            guard response.name == "iq",
                  response.attribute("type") == "result",
                  let queryResult = response.child(named: "query", namespace: XMPPNamespaces.register)
            else {
                throw RegistrationClientError.unexpectedResponse
            }

            await connection.disconnect()
            return RegistrationModule.parseForm(queryResult)
        } catch {
            await connection.disconnect()
            throw error
        }
    }

    /// Registers a new account on the server without authenticating first.
    public static func register(
        domain: String,
        username: String,
        password: String,
        email: String? = nil,
        host: String? = nil,
        port: UInt16 = 5222
    ) async throws {
        let connection = XMPPConnection(transport: POSIXTransport())
        let reader = EventReader(connection.events)

        do {
            if let host {
                try await connection.connect(host: host, port: port)
            } else {
                try await connection.connect(domain: domain)
            }

            try await negotiateStream(connection: connection, reader: reader, domain: domain)

            // Build registration IQ
            var iq = XMPPIQ(type: .set, id: "reg1")
            let query = RegistrationModule.buildRegistrationQuery(username: username, password: password, email: email)
            iq.element.addChild(query)
            try await connection.send(XMPPStreamWriter.stanza(iq.element))

            let response = try await awaitStanza(reader)
            guard response.name == "iq" else {
                throw RegistrationClientError.unexpectedResponse
            }

            if response.attribute("type") == "error" {
                var errorText = "Registration failed"
                if let errorElement = response.child(named: "error") {
                    for case let .element(child) in errorElement.children {
                        errorText = child.name
                        break
                    }
                }
                throw RegistrationClientError.registrationFailed(errorText)
            }

            guard response.attribute("type") == "result" else {
                throw RegistrationClientError.unexpectedResponse
            }

            log.info("Registration successful for \(username)@\(domain)")
            await connection.disconnect()
        } catch {
            await connection.disconnect()
            throw error
        }
    }

    // MARK: - Private

    private static func negotiateStream(
        connection: XMPPConnection,
        reader: EventReader,
        domain: String
    ) async throws {
        // Open stream
        try await connection.send(XMPPStreamWriter.streamOpening(to: domain))
        let features = try await awaitFeatures(reader)

        // STARTTLS if available
        if features.child(named: "starttls", namespace: XMPPNamespaces.tls) != nil {
            let starttls = XMLElement(name: "starttls", namespace: XMPPNamespaces.tls)
            try await connection.send(XMPPStreamWriter.stanza(starttls))

            let response = try await awaitStanza(reader)
            guard response.name == "proceed" else {
                throw RegistrationClientError.tlsNegotiationFailed
            }

            try await connection.upgradeTLS(serverName: domain)
            await connection.resetStream()

            // Reopen stream after TLS
            try await connection.send(XMPPStreamWriter.streamOpening(to: domain))
            _ = try await awaitFeatures(reader)
        } else {
            throw RegistrationClientError.tlsNegotiationFailed
        }
    }

    /// Wraps `EventReader.awaitFeatures()` to map errors to `RegistrationClientError`.
    private static func awaitFeatures(_ reader: EventReader) async throws -> XMLElement {
        do {
            return try await reader.awaitFeatures()
        } catch is XMPPClientError {
            throw RegistrationClientError.unexpectedResponse
        }
    }

    /// Wraps `EventReader.awaitStanza()` to map errors to `RegistrationClientError`.
    private static func awaitStanza(_ reader: EventReader) async throws -> XMLElement {
        do {
            return try await reader.awaitStanza()
        } catch is XMPPClientError {
            throw RegistrationClientError.unexpectedResponse
        }
    }
}
