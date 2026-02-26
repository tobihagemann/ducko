/// Orchestrates transport, XML stream parser, and event forwarding for an XMPP connection.
///
/// Owns a single unified ``events`` stream that survives parser resets across TLS upgrades.
/// On ``upgradeTLS(serverName:)``, the current parser is closed, a fresh one is created,
/// and event forwarding resumes — matching XMPP's "new stream" semantics.
actor XMPPConnection {
    private let transport: any XMPPTransport
    private var parser: XMPPStreamParser
    private var receiveTask: Task<Void, Never>?
    private var forwardTask: Task<Void, Never>?

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
        startForwarding()
        startReceiving()
    }

    // MARK: - TLS

    /// Upgrades the transport to TLS, resets the parser, and resumes event forwarding.
    ///
    /// Only the forward task is stopped — the receive task continues running.
    /// Parser access is actor-isolated, so queued `feedParser` calls will
    /// execute against the new parser after the swap.
    func upgradeTLS(serverName: String) async throws {
        resetStream()
        try await transport.upgradeTLS(serverName: serverName)
    }

    // MARK: - Stream Reset

    /// Resets the parser for a new XMPP stream (e.g. after SASL authentication).
    ///
    /// The receive task continues running — only the forward task is restarted
    /// with the new parser's event stream.
    func resetStream() {
        forwardTask?.cancel()
        forwardTask = nil
        parser.close()
        parser = XMPPStreamParser()
        startForwarding()
    }

    // MARK: - Sending

    /// Send raw bytes over the transport.
    func send(_ bytes: [UInt8]) async throws {
        try await transport.send(bytes)
    }

    // MARK: - Disconnecting

    /// Clean shutdown: stops tasks, closes parser, disconnects transport, finishes event stream.
    func disconnect() async {
        stopTasks()
        parser.close()
        await transport.disconnect()
        eventContinuation.finish()
    }

    // MARK: - Private

    private func startForwarding() {
        let parserEvents = parser.events
        let continuation = self.eventContinuation
        forwardTask = Task {
            for await event in parserEvents {
                continuation.yield(event)
            }
            if !Task.isCancelled {
                continuation.finish()
            }
        }
    }

    private func startReceiving() {
        let receivedData = transport.receivedData
        receiveTask = Task { [weak self] in
            for await bytes in receivedData {
                await self?.feedParser(bytes)
            }
            if !Task.isCancelled {
                await self?.closeParser()
            }
        }
    }

    private func feedParser(_ bytes: [UInt8]) {
        parser.parse(bytes)
    }

    private func closeParser() {
        parser.close()
    }

    private func stopTasks() {
        receiveTask?.cancel()
        receiveTask = nil
        forwardTask?.cancel()
        forwardTask = nil
    }
}
