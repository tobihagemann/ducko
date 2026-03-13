import os

private let log = Logger(subsystem: "com.ducko.xmpp", category: "registrationClient")

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

    // periphery:ignore - specced feature, not yet wired
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

            let response = try await reader.awaitStanza()
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

            let response = try await reader.awaitStanza()
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
        let features = try await reader.awaitFeatures()

        // STARTTLS if available
        if features.child(named: "starttls", namespace: XMPPNamespaces.tls) != nil {
            let starttls = XMLElement(name: "starttls", namespace: XMPPNamespaces.tls)
            try await connection.send(XMPPStreamWriter.stanza(starttls))

            let response = try await reader.awaitStanza()
            guard response.name == "proceed" else {
                throw RegistrationClientError.tlsNegotiationFailed
            }

            try await connection.upgradeTLS(serverName: domain)
            await connection.resetStream()

            // Reopen stream after TLS
            try await connection.send(XMPPStreamWriter.streamOpening(to: domain))
            _ = try await reader.awaitFeatures()
        } else {
            throw RegistrationClientError.tlsNegotiationFailed
        }
    }
}

/// Reads events from an XMPPConnection's event stream sequentially.
private final class EventReader: @unchecked Sendable {
    private var iterator: AsyncStream<XMLStreamEvent>.Iterator

    init(_ stream: AsyncStream<XMLStreamEvent>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func awaitFeatures() async throws -> XMLElement {
        // Wait for stream opened
        guard let openEvent = await iterator.next(),
              case .streamOpened = openEvent else {
            throw XMPPRegistrationClient.RegistrationClientError.unexpectedResponse
        }

        // Wait for features
        guard let featuresEvent = await iterator.next(),
              case let .stanzaReceived(features) = featuresEvent,
              features.name == "features" else {
            throw XMPPRegistrationClient.RegistrationClientError.unexpectedResponse
        }

        return features
    }

    func awaitStanza() async throws -> XMLElement {
        guard let event = await iterator.next(),
              case let .stanzaReceived(element) = event else {
            throw XMPPRegistrationClient.RegistrationClientError.unexpectedResponse
        }
        return element
    }
}
