/// Owns transport, XML parser, and the unified `events` stream. Parser is replaced on TLS upgrade
/// (XMPP "new stream" semantics) but `events` survives across resets.
actor XMPPConnection {
    private let transport: any XMPPTransport
    private var parser: XMPPStreamParser
    private var receiveTask: Task<Void, Never>?
    private(set) var isDirectTLS = false

    private let eventContinuation: AsyncStream<XMLStreamEvent>.Continuation

    /// Unified event stream that survives parser resets across TLS upgrades.
    nonisolated let events: AsyncStream<XMLStreamEvent>

    init(transport: any XMPPTransport = NWConnectionTransport()) {
        let (stream, continuation) = AsyncStream.makeStream(of: XMLStreamEvent.self)
        self.events = stream
        self.eventContinuation = continuation
        self.transport = transport
        self.parser = XMPPStreamParser()
    }

    // MARK: - Connecting

    /// SRV-aware connect: resolves SRV records and tries in priority order.
    func connect(domain: String) async throws {
        let records = await XMPPSRVLookup.resolve(domain: domain)
        var lastError: (any Error)?
        for record in records {
            do {
                if record.directTLS {
                    try await connectWithTLS(host: record.target, port: record.port, serverName: domain)
                } else {
                    try await connect(host: record.target, port: record.port)
                }
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? XMPPConnectionError.connectionFailed("No SRV records available")
    }

    /// Direct connect to a specific host and port.
    func connect(host: String, port: UInt16) async throws {
        isDirectTLS = false
        try await transport.connect(host: host, port: port)
        startReceiving()
    }

    /// Direct TLS connect — TLS from the first byte, no STARTTLS upgrade.
    func connectWithTLS(host: String, port: UInt16, serverName: String) async throws {
        try await transport.connectWithTLS(host: host, port: port, serverName: serverName)
        isDirectTLS = true
        startReceiving()
    }

    // MARK: - TLS

    /// Upgrades transport to TLS and resets the parser. Receive task keeps running; actor isolation ensures queued `feedParser` calls land on the post-swap parser.
    func upgradeTLS(serverName: String) async throws {
        resetStream()
        try await transport.upgradeTLS(serverName: serverName)
    }

    var tlsInfo: TLSInfo? {
        get async {
            if let posix = transport as? POSIXTransport {
                return await posix.tlsInfo
            }
            return nil
        }
    }

    var channelBindingData: [UInt8]? {
        get async {
            await transport.channelBindingData()
        }
    }

    // MARK: - Stream Reset

    /// Resets the parser for a new XMPP stream (e.g. after SASL). Receive task continues.
    func resetStream() {
        _ = parser.close()
        parser = XMPPStreamParser()
    }

    // MARK: - Sending

    func send(_ bytes: [UInt8]) async throws {
        try await transport.send(bytes)
    }

    // MARK: - Disconnecting

    /// Sends the closing `</stream:stream>` tag and briefly waits for the server's response.
    func sendStreamClose() async {
        try? await transport.send(XMPPStreamWriter.streamClosing())
        try? await Task.sleep(for: .milliseconds(100))
    }

    /// Clean shutdown: stops tasks, closes parser, disconnects transport, finishes event stream.
    func disconnect() async {
        stopTasks()
        _ = parser.close()
        isDirectTLS = false
        await transport.disconnect()
        eventContinuation.finish()
    }

    private func startReceiving() {
        let receivedData = transport.receivedData
        receiveTask = Task { [weak self] in
            for await bytes in receivedData {
                await self?.feedParser(bytes)
            }
            if !Task.isCancelled {
                await self?.closeParser()
                await self?.finishEvents()
            }
        }
    }

    private func feedParser(_ bytes: [UInt8]) {
        let events = parser.parse(bytes)
        for event in events {
            eventContinuation.yield(event)
        }
    }

    private func closeParser() {
        let events = parser.close()
        for event in events {
            eventContinuation.yield(event)
        }
    }

    private func finishEvents() {
        eventContinuation.finish()
    }

    private func stopTasks() {
        receiveTask?.cancel()
        receiveTask = nil
    }
}
