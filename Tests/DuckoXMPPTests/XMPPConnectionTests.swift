import Testing
@testable import DuckoXMPP

// MARK: - Mock Transport

/// Actor-based mock transport for testing ``XMPPConnection`` without real networking.
actor MockTransport: XMPPTransport {
    nonisolated let receivedData: AsyncStream<[UInt8]>
    private let receivedContinuation: AsyncStream<[UInt8]>.Continuation
    private(set) var sentBytes: [[UInt8]] = []
    private(set) var isConnected = false
    private(set) var isTLSUpgraded = false
    private(set) var connectedHost: String?
    private(set) var connectedPort: UInt16?

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        self.receivedData = stream
        self.receivedContinuation = continuation
    }

    func connect(host: String, port: UInt16) async throws {
        guard !isConnected else {
            throw XMPPConnectionError.alreadyConnected
        }
        isConnected = true
        connectedHost = host
        connectedPort = port
    }

    func upgradeTLS(serverName: String) async throws {
        guard isConnected else {
            throw XMPPConnectionError.notConnected
        }
        isTLSUpgraded = true
    }

    func send(_ bytes: [UInt8]) async throws {
        guard isConnected else {
            throw XMPPConnectionError.notConnected
        }
        sentBytes.append(bytes)
    }

    func disconnect() {
        isConnected = false
        receivedContinuation.finish()
    }

    // MARK: - Test Helpers

    /// Simulates receiving data from the network.
    func simulateReceive(_ bytes: [UInt8]) {
        receivedContinuation.yield(bytes)
    }

    /// Simulates receiving a UTF-8 string from the network.
    func simulateReceive(_ string: String) {
        receivedContinuation.yield(Array(string.utf8))
    }

    /// Simulates the remote end closing the connection.
    func simulateDisconnect() {
        receivedContinuation.finish()
    }
}

// MARK: - Helpers

private let streamOpenTag =
    "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' from='example.com' version='1.0'>"

/// Collects events from a connection until `predicate` returns `true`, with a timeout.
private func collectEvents(
    from connection: XMPPConnection,
    timeout: Duration = .seconds(2),
    until predicate: @Sendable @escaping (XMLStreamEvent) -> Bool
) async throws -> [XMLStreamEvent] {
    try await withThrowingTaskGroup(of: [XMLStreamEvent].self) { group in
        group.addTask {
            var collected: [XMLStreamEvent] = []
            for await event in connection.events {
                collected.append(event)
                if predicate(event) { break }
            }
            return collected
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw XMPPConnectionError.connectionTimeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

// MARK: - Tests

enum XMPPConnectionTests {
    struct ConnectionLifecycle {
        @Test("Connect establishes transport")
        func connectEstablishesTransport() async throws {
            let mock = MockTransport()
            let connection = XMPPConnection(transport: mock)

            try await connection.connect(host: "example.com", port: 5222)

            let isConnected = await mock.isConnected
            let host = await mock.connectedHost
            let port = await mock.connectedPort
            #expect(isConnected)
            #expect(host == "example.com")
            #expect(port == 5222)

            await connection.disconnect()
        }

        @Test("Disconnect stops transport and finishes events")
        func disconnectStopsAndFinishes() async throws {
            let mock = MockTransport()
            let connection = XMPPConnection(transport: mock)

            try await connection.connect(host: "example.com", port: 5222)
            await connection.disconnect()

            let isConnected = await mock.isConnected
            #expect(!isConnected)

            // Event stream should terminate
            var events: [XMLStreamEvent] = []
            for await event in connection.events {
                events.append(event)
            }
            #expect(events.isEmpty)
        }
    }

    struct DataReceiving {
        @Test("Received bytes emit XML stream events")
        func receivedBytesEmitXMLStreamEvents() async throws {
            let mock = MockTransport()
            let connection = XMPPConnection(transport: mock)

            try await connection.connect(host: "example.com", port: 5222)

            // Simulate server sending stream open + a stanza
            await mock.simulateReceive(streamOpenTag)
            await mock.simulateReceive("<message><body>Hello</body></message>")
            await mock.simulateDisconnect()

            var events: [XMLStreamEvent] = []
            for await event in connection.events {
                events.append(event)
            }

            // Should have at least streamOpened + stanzaReceived
            let hasStreamOpen = events.contains { $0.streamOpenedAttributes != nil }
            let stanzas = events.compactMap(\.stanzaElement)
            #expect(hasStreamOpen)
            #expect(stanzas.count == 1)
            #expect(stanzas[0].name == "message")
            #expect(stanzas[0].child(named: "body")?.textContent == "Hello")

            await connection.disconnect()
        }

        @Test("Incremental chunks produce correct stanzas")
        func incrementalChunksProduceCorrectStanzas() async throws {
            let mock = MockTransport()
            let connection = XMPPConnection(transport: mock)

            try await connection.connect(host: "example.com", port: 5222)

            // Send stream open + a stanza split across chunks
            await mock.simulateReceive(streamOpenTag)
            await mock.simulateReceive("<message><bo")
            await mock.simulateReceive("dy>Split</body></message>")
            await mock.simulateDisconnect()

            var events: [XMLStreamEvent] = []
            for await event in connection.events {
                events.append(event)
            }

            let stanzas = events.compactMap(\.stanzaElement)
            #expect(stanzas.count == 1)
            #expect(stanzas[0].child(named: "body")?.textContent == "Split")

            await connection.disconnect()
        }
    }

    struct TLSUpgrade {
        @Test("Upgrade resets parser and resumes receiving")
        func upgradeResetsParserAndResumesReceiving() async throws {
            let mock = MockTransport()
            let connection = XMPPConnection(transport: mock)

            try await connection.connect(host: "example.com", port: 5222)

            let isTLSBefore = await mock.isTLSUpgraded
            #expect(!isTLSBefore)

            try await connection.upgradeTLS(serverName: "example.com")

            let isTLSAfter = await mock.isTLSUpgraded
            #expect(isTLSAfter)

            await connection.disconnect()
        }

        @Test("Events flow after TLS upgrade")
        func eventsFlowAfterTLSUpgrade() async throws {
            let mock = MockTransport()
            let connection = XMPPConnection(transport: mock)

            try await connection.connect(host: "example.com", port: 5222)
            try await connection.upgradeTLS(serverName: "example.com")

            await mock.simulateReceive(streamOpenTag)
            await mock.simulateReceive("<message><body>After TLS</body></message>")

            let events = try await collectEvents(from: connection) {
                $0.stanzaElement != nil
            }

            let stanza = try #require(events.compactMap(\.stanzaElement).first)
            #expect(stanza.child(named: "body")?.textContent == "After TLS")

            await connection.disconnect()
        }
    }

    struct Sending {
        @Test("Send forwards bytes to transport")
        func sendForwardsBytesToTransport() async throws {
            let mock = MockTransport()
            let connection = XMPPConnection(transport: mock)

            try await connection.connect(host: "example.com", port: 5222)

            let bytes: [UInt8] = Array("<presence/>".utf8)
            try await connection.send(bytes)

            let sent = await mock.sentBytes
            #expect(sent.count == 1)
            #expect(sent[0] == bytes)

            await connection.disconnect()
        }
    }
}

// MARK: - SRV Record Tests

struct SRVRecordTests {
    @Test("Sorts by priority then weight")
    func sortsByPriorityThenWeight() {
        let records = [
            SRVRecord(priority: 20, weight: 50, port: 5222, target: "low-pri.example.com"),
            SRVRecord(priority: 10, weight: 30, port: 5222, target: "high-pri-low-weight.example.com"),
            SRVRecord(priority: 10, weight: 70, port: 5222, target: "high-pri-high-weight.example.com")
        ]

        let sorted = records.sorted()
        #expect(sorted[0].target == "high-pri-high-weight.example.com")
        #expect(sorted[1].target == "high-pri-low-weight.example.com")
        #expect(sorted[2].target == "low-pri.example.com")
    }

    @Test("Fallback on empty results returns domain:5222")
    func fallbackOnEmptyResults() async {
        // Use an invalid domain that will definitely fail SRV lookup
        let records = await XMPPSRVLookup.resolve(
            domain: "this-domain-does-not-exist-12345.invalid",
            timeout: .seconds(2)
        )
        #expect(records.count == 1)
        #expect(records[0].port == 5222)
        #expect(records[0].target == "this-domain-does-not-exist-12345.invalid")
    }
}
