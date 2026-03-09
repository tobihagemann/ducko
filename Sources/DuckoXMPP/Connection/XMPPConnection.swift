/// Orchestrates transport, XML stream parser, and event delivery for an XMPP connection.
///
/// Owns a single unified ``events`` stream that survives parser resets across TLS upgrades.
/// On ``upgradeTLS(serverName:)``, the current parser is closed and a fresh one is created
/// — matching XMPP's "new stream" semantics.
actor XMPPConnection {
    private let transport: any XMPPTransport
    private var parser: XMPPStreamParser
    private var receiveTask: Task<Void, Never>?

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
                try await connect(host: record.target, port: record.port)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? XMPPConnectionError.connectionFailed("No SRV records available")
    }

    /// Direct connect to a specific host and port.
    func connect(host: String, port: UInt16) async throws {
        try await transport.connect(host: host, port: port)
        startReceiving()
    }

    // MARK: - TLS

    /// Upgrades the transport to TLS and resets the parser.
    ///
    /// The receive task continues running. Parser access is actor-isolated,
    /// so queued `feedParser` calls will execute against the new parser after the swap.
    func upgradeTLS(serverName: String) async throws {
        resetStream()
        try await transport.upgradeTLS(serverName: serverName)
    }

    /// Returns TLS info from the transport, if available.
    var tlsInfo: TLSInfo? {
        get async {
            if let posix = transport as? POSIXTransport {
                return await posix.tlsInfo
            }
            return nil
        }
    }

    // MARK: - Stream Reset

    /// Resets the parser for a new XMPP stream (e.g. after SASL authentication).
    ///
    /// The receive task continues running — only the parser is replaced.
    func resetStream() {
        _ = parser.close()
        parser = XMPPStreamParser()
    }

    // MARK: - Sending

    /// Send raw bytes over the transport.
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
        await transport.disconnect()
        eventContinuation.finish()
    }

    // MARK: - Private

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
