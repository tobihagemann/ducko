import os
import Synchronization

/// Orchestrates the full XMPP connection flow and dispatches stanzas to feature modules.
///
/// Drives: TCP → STARTTLS → SASL → resource binding → session establishment.
/// Incoming stanzas are routed to registered ``XMPPModule``s. Domain-level events
/// are exposed via ``events``.
actor XMPPClient {
    private let connection: XMPPConnection
    private let domain: String
    private let credentials: Credentials
    private var modules: [ObjectIdentifier: any XMPPModule] = [:]
    private var state: ConnectionState = .disconnected
    private var readerTask: Task<Void, Never>?
    private var pendingIQs: [String: CheckedContinuation<XMLElement?, any Error>] = [:]
    private let idCounter = Atomic<UInt64>(0)
    private let connectedJIDLock = OSAllocatedUnfairLock<FullJID?>(initialState: nil)

    private let eventContinuation: AsyncStream<XMPPEvent>.Continuation

    /// Domain events from the client (connected, disconnected, messages, etc.).
    nonisolated let events: AsyncStream<XMPPEvent>

    struct Credentials: Sendable {
        let username: String
        let password: String
    }

    // MARK: - Connection State

    enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case negotiatingTLS
        case authenticating
        case bindingResource
        case connected(FullJID)
    }

    // MARK: - Init

    init(domain: String, credentials: Credentials, transport: any XMPPTransport = NWConnectionTransport()) {
        let (stream, continuation) = AsyncStream.makeStream(of: XMPPEvent.self)
        self.events = stream
        self.eventContinuation = continuation
        self.domain = domain
        self.credentials = credentials
        self.connection = XMPPConnection(transport: transport)
    }

    // MARK: - Module Registration

    func register<M: XMPPModule>(_ module: M) {
        let key = ObjectIdentifier(type(of: module))
        modules[key] = module
        module.setUp(makeModuleContext())
    }

    func module<M: XMPPModule>(ofType type: M.Type) -> M? {
        modules[ObjectIdentifier(type)] as? M
    }

    // MARK: - ID Generation

    nonisolated func generateID() -> String {
        let value = idCounter.wrappingAdd(1, ordering: .relaxed).oldValue &+ 1
        return "ducko-\(value)"
    }

    // MARK: - Connect

    /// SRV-aware connect: resolves SRV records then runs the full XMPP handshake.
    func connect() async throws {
        try await performConnect { [connection, domain] in
            try await connection.connect(domain: domain)
        }
    }

    /// Direct connect to a specific host and port, bypassing SRV resolution.
    func connect(host: String, port: UInt16) async throws {
        try await performConnect { [connection] in
            try await connection.connect(host: host, port: port)
        }
    }

    private func performConnect(establish: () async throws -> Void) async throws {
        guard case .disconnected = state else {
            throw XMPPClientError.alreadyConnected
        }
        state = .connecting

        do {
            try await establish()
        } catch {
            state = .disconnected
            throw error
        }

        let reader = EventReader(connection.events)

        do {
            try await performHandshake(reader: reader)
            startReader(reader: reader)
        } catch {
            state = .disconnected
            await connection.disconnect()
            throw error
        }
    }

    /// Drives the full XMPP handshake consuming events via the reader.
    private func performHandshake(reader: EventReader) async throws {
        // 1. Open initial stream
        try await openStream()
        let features1 = try await reader.awaitFeatures()

        // 2. STARTTLS if offered
        let postTLSFeatures: XMLElement
        if features1.child(named: "starttls", namespace: XMPPNamespaces.tls) != nil {
            state = .negotiatingTLS
            try await negotiateTLS(reader: reader)
            try await openStream()
            postTLSFeatures = try await reader.awaitFeatures()
        } else {
            postTLSFeatures = features1
        }

        // 3. SASL authentication
        state = .authenticating
        try await authenticate(features: postTLSFeatures, reader: reader)

        // 4. Post-auth stream (reset parser for new XML document)
        await connection.resetStream()
        try await openStream()
        let features3 = try await reader.awaitFeatures()

        // 5. Resource binding
        state = .bindingResource
        let fullJID = try await bindResource(reader: reader)

        // 6. Session establishment (if required)
        if let session = features3.child(named: "session", namespace: XMPPNamespaces.session),
           session.child(named: "optional") == nil {
            try await establishSession(reader: reader)
        }

        // 7. Connected
        connectedJIDLock.withLock { $0 = fullJID }
        state = .connected(fullJID)
        eventContinuation.yield(.connected(fullJID))

        for module in modules.values {
            try await module.handleConnect()
        }
    }

    // MARK: - Disconnect

    func disconnect() async {
        cleanUp(reason: .requested)
        await connection.disconnect()
    }

    // MARK: - Sending

    func send(_ stanza: any XMPPStanza) async throws {
        guard case .connected = state else {
            throw XMPPClientError.notConnected
        }
        try await connection.send(XMPPStreamWriter.stanza(stanza.element))
    }

    /// Sends an IQ and awaits the matching result/error response.
    /// Returns the result's child element, or `nil` for IQ errors.
    func sendIQ(_ iq: XMPPIQ) async throws -> XMLElement? {
        var iq = iq
        let stanzaID = iq.id ?? generateID()
        iq.id = stanzaID

        return try await withCheckedThrowingContinuation { continuation in
            pendingIQs[stanzaID] = continuation
            Task { [connection] in
                do {
                    try await connection.send(XMPPStreamWriter.stanza(iq.element))
                } catch {
                    if let continuation = self.pendingIQs.removeValue(forKey: stanzaID) {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - Private: Stream Negotiation

    private func openStream() async throws {
        try await connection.send(XMPPStreamWriter.streamOpening(to: domain))
    }

    private func negotiateTLS(reader: EventReader) async throws {
        let starttls = XMLElement(name: "starttls", namespace: XMPPNamespaces.tls)
        try await connection.send(XMPPStreamWriter.stanza(starttls))

        let element = try await reader.awaitStanza()

        guard element.name == "proceed" else {
            throw XMPPClientError.tlsNegotiationFailed("Server rejected STARTTLS: \(element.name)")
        }

        try await connection.upgradeTLS(serverName: domain)
    }

    // MARK: - Private: Authentication

    private func authenticate(features: XMLElement, reader: EventReader) async throws {
        var authenticator = SASLAuthenticator()
        let authElement: XMLElement
        do {
            authElement = try authenticator.begin(
                features: features, authcid: credentials.username, password: credentials.password
            )
        } catch {
            let message = String(describing: error)
            eventContinuation.yield(.authenticationFailed(message))
            throw XMPPClientError.authenticationFailed(message)
        }

        try await connection.send(XMPPStreamWriter.stanza(authElement))

        // Drive the SASL exchange
        while true {
            let element = try await reader.awaitStanza()

            let response = authenticator.receive(element)
            switch response {
            case .continueWith(let reply):
                try await connection.send(XMPPStreamWriter.stanza(reply))
            case .success:
                return
            case .failure(let error):
                let message = String(describing: error)
                eventContinuation.yield(.authenticationFailed(message))
                throw XMPPClientError.authenticationFailed(message)
            }
        }
    }

    // MARK: - Private: Resource Binding

    private func bindResource(reader: EventReader) async throws -> FullJID {
        var bindIQ = XMPPIQ(type: .set, id: generateID())
        let bindChild = XMLElement(name: "bind", namespace: XMPPNamespaces.bind)
        bindIQ.element.addChild(bindChild)

        try await connection.send(XMPPStreamWriter.stanza(bindIQ.element))

        let element = try await reader.awaitStanza()

        let resultIQ = XMPPIQ(element: element)
        guard resultIQ.isResult else {
            throw XMPPClientError.bindingFailed("Bind IQ returned type=\(resultIQ.type ?? "nil")")
        }

        guard let bind = resultIQ.childElement,
              let jidString = bind.childText(named: "jid"),
              let fullJID = FullJID.parse(jidString) else {
            throw XMPPClientError.bindingFailed("No JID in bind result")
        }

        return fullJID
    }

    // MARK: - Private: Session

    private func establishSession(reader: EventReader) async throws {
        var sessionIQ = XMPPIQ(type: .set, id: generateID())
        let sessionChild = XMLElement(name: "session", namespace: XMPPNamespaces.session)
        sessionIQ.element.addChild(sessionChild)

        try await connection.send(XMPPStreamWriter.stanza(sessionIQ.element))

        let element = try await reader.awaitStanza()

        let resultIQ = XMPPIQ(element: element)
        guard resultIQ.isResult else {
            throw XMPPClientError.sessionFailed("Session IQ returned type=\(resultIQ.type ?? "nil")")
        }
    }

    // MARK: - Private: Event Reader

    /// Wraps an `AsyncStream` iterator for cross-isolation event consumption.
    ///
    /// `@unchecked Sendable` because `AsyncStream.Iterator.next()` is nonisolated async,
    /// requiring the iterator to cross actor isolation boundaries. Safe because all access
    /// is sequential — only one caller consumes events at a time (handshake then dispatch).
    private final class EventReader: @unchecked Sendable {
        private var iterator: AsyncStream<XMLStreamEvent>.Iterator

        init(_ stream: AsyncStream<XMLStreamEvent>) {
            self.iterator = stream.makeAsyncIterator()
        }

        func next() async -> XMLStreamEvent? {
            await iterator.next()
        }

        func awaitNextEvent() async throws -> XMLStreamEvent {
            guard let event = await iterator.next() else {
                throw XMPPClientError.unexpectedStreamState("Stream ended unexpectedly")
            }
            return event
        }

        func awaitFeatures() async throws -> XMLElement {
            let openEvent = try await awaitNextEvent()
            guard case .streamOpened = openEvent else {
                throw XMPPClientError.unexpectedStreamState("Expected stream opened")
            }
            let featuresEvent = try await awaitNextEvent()
            guard case .stanzaReceived(let features) = featuresEvent, features.name == "features" else {
                throw XMPPClientError.unexpectedStreamState("Expected stream features")
            }
            return features
        }

        func awaitStanza() async throws -> XMLElement {
            let event = try await awaitNextEvent()
            guard case .stanzaReceived(let element) = event else {
                throw XMPPClientError.unexpectedStreamState("Expected stanza")
            }
            return element
        }
    }

    // MARK: - Private: Dispatch Loop

    private func startReader(reader: EventReader) {
        readerTask = Task { [weak self] in
            while let event = await reader.next() {
                guard let self else { return }
                await self.handleEvent(event)
            }
            await self?.handleStreamEnd()
        }
    }

    private func handleEvent(_ event: XMLStreamEvent) {
        switch event {
        case .streamOpened:
            break
        case .stanzaReceived(let element):
            dispatchStanza(element)
        case .streamClosed:
            cleanUp(reason: .streamError("Stream closed by server"))
        case .error(let error):
            cleanUp(reason: .connectionLost(error.message))
        }
    }

    private func dispatchStanza(_ element: XMLElement) {
        switch element.name {
        case "message":
            let message = XMPPMessage(element: element)
            eventContinuation.yield(.messageReceived(message))
            for module in modules.values {
                try? module.handleMessage(message)
            }
        case "presence":
            let presence = XMPPPresence(element: element)
            eventContinuation.yield(.presenceReceived(presence))
            for module in modules.values {
                try? module.handlePresence(presence)
            }
        case "iq":
            let iq = XMPPIQ(element: element)
            if let stanzaID = iq.id, let continuation = pendingIQs.removeValue(forKey: stanzaID) {
                continuation.resume(returning: iq.isResult ? iq.childElement : nil)
                return
            }
            eventContinuation.yield(.iqReceived(iq))
            for module in modules.values {
                try? module.handleIQ(iq)
            }
        default:
            break
        }
    }

    private func handleStreamEnd() {
        guard case .connected = state else { return }
        cleanUp(reason: .connectionLost("Stream ended"))
    }

    // MARK: - Private: Cleanup

    private func cleanUp(reason: DisconnectReason) {
        readerTask?.cancel()
        readerTask = nil
        state = .disconnected
        connectedJIDLock.withLock { $0 = nil }

        for continuation in pendingIQs.values {
            continuation.resume(throwing: XMPPClientError.notConnected)
        }
        pendingIQs.removeAll()

        eventContinuation.yield(.disconnected(reason))
    }

    // MARK: - Private: Module Context

    private func makeModuleContext() -> ModuleContext {
        ModuleContext(
            sendStanza: { [weak self] stanza in
                try await self?.send(stanza)
            },
            sendIQ: { [weak self] iq in
                try await self?.sendIQ(iq)
            },
            emitEvent: { [eventContinuation] event in
                eventContinuation.yield(event)
            },
            generateID: { [self] in
                self.generateID()
            },
            connectedJID: { [connectedJIDLock] in
                connectedJIDLock.withLock { $0 }
            }
        )
    }
}
