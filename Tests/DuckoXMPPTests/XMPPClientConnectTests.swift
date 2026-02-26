import Testing

@testable import DuckoXMPP

// MARK: - Diagnostic tests verifying EventReader + connection.events pattern

private let streamOpen =
    "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' from='example.com' version='1.0'>"

private let featuresNoTLS = """
    <features xmlns='http://etherx.jabber.org/streams'>\
    <mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\
    <mechanism>PLAIN</mechanism>\
    </mechanisms>\
    </features>
    """

private final class TestReader: @unchecked Sendable {
    private var iterator: AsyncStream<XMLStreamEvent>.Iterator
    init(_ stream: AsyncStream<XMLStreamEvent>) {
        self.iterator = stream.makeAsyncIterator()
    }
    func next() async -> XMLStreamEvent? {
        await iterator.next()
    }
}

// MARK: - Stream reset after SASL re-stream

private actor HandshakeActor {
    private let connection: XMPPConnection

    init(transport: any XMPPTransport) {
        self.connection = XMPPConnection(transport: transport)
    }

    func run() async throws {
        try await connection.connect(host: "example.com", port: 5222)
        let reader = TestReader(connection.events)

        // Open stream
        try await connection.send(XMPPStreamWriter.streamOpening(to: "example.com"))

        // Await features (2 events)
        let e1 = await reader.next()
        guard case .streamOpened = e1 else {
            throw XMPPClientError.unexpectedStreamState("Expected .streamOpened")
        }
        let e2 = await reader.next()
        guard case .stanzaReceived(let features) = e2, features.name == "features" else {
            throw XMPPClientError.unexpectedStreamState("Expected features")
        }

        // Send auth
        var auth = XMLElement(name: "auth", namespace: "urn:ietf:params:xml:ns:xmpp-sasl")
        auth.setAttribute("mechanism", value: "PLAIN")
        auth.addText("AHVzZXIAcGFzcw==")
        try await connection.send(XMPPStreamWriter.stanza(auth))

        // Await auth response
        let e3 = await reader.next()
        guard case .stanzaReceived(let success) = e3, success.name == "success" else {
            throw XMPPClientError.unexpectedStreamState("Expected success")
        }

        // Re-open stream (reset parser for new XML document)
        await connection.resetStream()
        try await connection.send(XMPPStreamWriter.streamOpening(to: "example.com"))

        // Await features again (2 more events)
        let e4 = await reader.next()
        guard case .streamOpened = e4 else {
            throw XMPPClientError.unexpectedStreamState("Expected .streamOpened (post-auth)")
        }
        let e5 = await reader.next()
        guard case .stanzaReceived(let features2) = e5, features2.name == "features" else {
            throw XMPPClientError.unexpectedStreamState("Expected features (post-auth)")
        }

        await connection.disconnect()
    }
}

@Test("Parser reset enables post-SASL stream re-open")
func parserResetEnablesPostSASLRestream() async throws {
    let mock = MockTransport()
    let actor = HandshakeActor(transport: mock)

    let task = Task { try await actor.run() }

    try await Task.sleep(for: .milliseconds(100))

    // 1. Stream open + features
    await mock.simulateReceive(streamOpen)
    try await Task.sleep(for: .milliseconds(50))
    await mock.simulateReceive(featuresNoTLS)
    try await Task.sleep(for: .milliseconds(50))

    // 2. Auth success
    await mock.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
    try await Task.sleep(for: .milliseconds(50))

    // 3. Post-auth stream open + bind features
    await mock.simulateReceive(streamOpen)
    try await Task.sleep(for: .milliseconds(50))
    await mock.simulateReceive("""
        <features xmlns='http://etherx.jabber.org/streams'>\
        <bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>\
        </features>
        """)

    try await task.value
}
