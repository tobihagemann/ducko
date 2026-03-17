import os
import Synchronization

private let log = Logger(subsystem: "com.ducko.xmpp", category: "client")

/// Orchestrates the full XMPP connection flow and dispatches stanzas to feature modules.
///
/// Drives: TCP → STARTTLS → SASL → resource binding → session establishment.
/// Incoming stanzas are routed to registered ``XMPPModule``s. Domain-level events
/// are exposed via ``events``.
public actor XMPPClient {
    private let connection: XMPPConnection
    private let domain: String
    private let credentials: Credentials
    private var modules: [ObjectIdentifier: any XMPPModule] = [:]
    private var interceptors: [any StanzaInterceptor] = []
    private var state: ConnectionState = .disconnected
    private var readerTask: Task<Void, Never>?
    private var pendingIQs: [String: PendingIQ] = [:]
    private let idCounter = Atomic<UInt64>(0)
    private let tlsInfoLock = OSAllocatedUnfairLock<TLSInfo?>(initialState: nil)
    private let connectedJIDLock = OSAllocatedUnfairLock<FullJID?>(initialState: nil)
    private let featuresLock = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    private let serverFeaturesLock = OSAllocatedUnfairLock<XMLElement?>(initialState: nil)

    private struct PendingIQ {
        let continuation: CheckedContinuation<XMLElement?, any Error>
        let expectedFrom: BareJID?
        let timeoutTask: Task<Void, Never>
    }

    private let eventContinuation: AsyncStream<XMPPEvent>.Continuation

    /// Domain events from the client (connected, disconnected, messages, etc.).
    public nonisolated let events: AsyncStream<XMPPEvent>

    public struct Credentials: Sendable {
        public let username: String
        public let password: String

        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    // MARK: - Connection State

    public enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case negotiatingTLS
        case authenticating
        case bindingResource
        case connected(FullJID)
    }

    // MARK: - Init

    private let requireTLS: Bool

    public init(domain: String, credentials: Credentials, transport: (any XMPPTransport)? = nil, requireTLS: Bool = true) {
        let (stream, continuation) = AsyncStream.makeStream(of: XMPPEvent.self)
        self.events = stream
        self.eventContinuation = continuation
        self.domain = domain
        self.credentials = credentials
        self.connection = XMPPConnection(transport: transport ?? POSIXTransport())
        self.requireTLS = requireTLS
    }

    // MARK: - Module Registration

    public func register(_ module: some XMPPModule) {
        let key = ObjectIdentifier(type(of: module))
        modules[key] = module
        module.setUp(makeModuleContext())
        let allFeatures = Set(modules.values.flatMap(\.features))
        featuresLock.withLock { $0 = allFeatures }
    }

    public func module<M: XMPPModule>(ofType type: M.Type) -> M? {
        modules[ObjectIdentifier(type)] as? M
    }

    // MARK: - Interceptor Registration

    public func addInterceptor(_ interceptor: any StanzaInterceptor) {
        interceptors.append(interceptor)
    }

    // MARK: - TLS Info

    /// Returns TLS connection info, or `nil` if TLS is not active.
    public nonisolated var tlsInfo: TLSInfo? {
        tlsInfoLock.withLock { $0 }
    }

    // MARK: - Features

    /// Union of all feature namespaces declared by registered modules.
    public var availableFeatures: Set<String> {
        Set(modules.values.flatMap(\.features))
    }

    // MARK: - ID Generation

    public nonisolated func generateID() -> String {
        let value = idCounter.wrappingAdd(1, ordering: .relaxed).oldValue &+ 1
        return "ducko-\(value)"
    }

    // MARK: - Connect

    /// SRV-aware connect: resolves SRV records then runs the full XMPP handshake.
    public func connect() async throws {
        try await performConnect { [connection, domain] in
            try await connection.connect(domain: domain)
        }
    }

    /// Direct connect to a specific host and port, bypassing SRV resolution.
    public func connect(host: String, port: UInt16) async throws {
        try await performConnect { [connection] in
            try await connection.connect(host: host, port: port)
        }
    }

    /// Direct TLS connect — TLS from the first byte, no STARTTLS upgrade.
    public func connectWithTLS(host: String, port: UInt16) async throws {
        try await performConnect { [connection, domain] in
            try await connection.connectWithTLS(host: host, port: port, serverName: domain)
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
            log.error("Connection failed: \(String(describing: error), privacy: .public)")
            state = .disconnected
            throw error
        }

        let reader = EventReader(connection.events)

        do {
            let resumed = try await performHandshake(reader: reader)
            startReader(reader: reader)
            if resumed {
                for module in modules.values {
                    try await module.handleResume()
                }
            } else {
                for module in modules.values {
                    try await module.handleConnect()
                }
            }
        } catch {
            log.error("Handshake failed: \(String(describing: error), privacy: .public)")
            serverFeaturesLock.withLock { $0 = nil }
            state = .disconnected
            await connection.disconnect()
            throw error
        }
    }

    /// Drives the full XMPP handshake consuming events via the reader.
    /// Returns `true` if the session was resumed (skip `handleConnect` on modules).
    private func performHandshake(reader: EventReader) async throws -> Bool {
        // 1. Open initial stream
        try await openStream()
        let features1 = try await reader.awaitFeatures()

        // 2. TLS — skip STARTTLS if direct TLS is already active
        let postTLSFeatures = try await negotiateTLSIfNeeded(features1, reader: reader)

        // 3. Prefer SASL2 + Bind 2 when both available
        if let sasl2Features = SASL2Authenticator.parseFeatures(postTLSFeatures),
           sasl2Features.supportsBind2 {
            return try await performSASL2Flow(postTLSFeatures, sasl2Features: sasl2Features, reader: reader)
        }

        // 4. Fallback: SASL1 + sequential bind
        return try await performSASL1Flow(postTLSFeatures, reader: reader)
    }

    /// Handles TLS negotiation (STARTTLS or direct TLS). Returns post-TLS features.
    private func negotiateTLSIfNeeded(_ features: XMLElement, reader: EventReader) async throws -> XMLElement {
        if await connection.isDirectTLS {
            log.info("Direct TLS active")
            let info = await connection.tlsInfo
            tlsInfoLock.withLock { $0 = info }
            return features
        } else if features.child(named: "starttls", namespace: XMPPNamespaces.tls) != nil {
            state = .negotiatingTLS
            try await negotiateTLS(reader: reader)
            log.info("TLS established via STARTTLS")
            let info = await connection.tlsInfo
            tlsInfoLock.withLock { $0 = info }
            try await openStream()
            return try await reader.awaitFeatures()
        } else if requireTLS {
            throw XMPPClientError.tlsRequired
        } else {
            return features
        }
    }

    // MARK: - Private: SASL2 + Bind 2

    /// Performs the SASL2 + Bind 2 authentication and binding flow.
    private func performSASL2Flow(
        _ features: XMLElement,
        sasl2Features: SASL2Features,
        reader: EventReader
    ) async throws -> Bool {
        state = .authenticating
        let requestedCarbons = sasl2Features.supportsBind2
            && modules[ObjectIdentifier(CarbonsModule.self)] != nil
        let authResult = try await authenticateSASL2(features: features, sasl2Features: sasl2Features, reader: reader)
        log.info("Authenticated via SASL2")

        // Post-auth stream reset (still required after SASL2 per RFC 6120 §6.3.2)
        await connection.resetStream()
        try await openStream()
        let postAuthFeatures = try await reader.awaitFeatures()
        serverFeaturesLock.withLock { $0 = postAuthFeatures }

        // Process inline results (SM enabled, carbons, etc.)
        let fullJID = authResult.fullJID
        connectedJIDLock.withLock { $0 = fullJID }
        processBind2Results(authResult, requestedCarbons: requestedCarbons)

        log.notice("Connected as \(fullJID) via SASL2 + Bind 2")
        state = .connected(fullJID)
        eventContinuation.yield(.connected(fullJID))
        return false
    }

    /// Performs the legacy SASL1 + sequential bind flow.
    private func performSASL1Flow(_ features: XMLElement, reader: EventReader) async throws -> Bool {
        state = .authenticating
        try await authenticate(features: features, reader: reader)
        log.info("Authenticated")

        // Post-auth stream (reset parser for new XML document)
        await connection.resetStream()
        try await openStream()
        let features3 = try await reader.awaitFeatures()
        serverFeaturesLock.withLock { $0 = features3 }

        // Attempt SM resume (before bind)
        if try await attemptSMResume(features: features3, reader: reader) {
            return true
        }

        // Resource binding
        state = .bindingResource
        let fullJID = try await bindResource(reader: reader)

        // Session establishment (if required)
        if let session = features3.child(named: "session", namespace: XMPPNamespaces.session),
           session.child(named: "optional") == nil {
            try await establishSession(reader: reader)
        }

        log.notice("Connected as \(fullJID)")
        connectedJIDLock.withLock { $0 = fullJID }
        state = .connected(fullJID)
        eventContinuation.yield(.connected(fullJID))
        return false
    }

    // MARK: - Disconnect

    public func disconnect() async {
        // Send unavailable presence before closing
        if case .connected = state {
            let unavailable = XMPPPresence(type: .unavailable)
            try? await connection.send(XMPPStreamWriter.stanza(unavailable.element))
        }

        await connection.sendStreamClose()
        await cleanUp(reason: .requested)
        await connection.disconnect()
    }

    // MARK: - Sending

    public func send(_ stanza: any XMPPStanza) async throws {
        guard case .connected = state else {
            throw XMPPClientError.notConnected
        }
        for interceptor in interceptors {
            interceptor.processOutgoing(stanza.element)
        }
        try await connection.send(XMPPStreamWriter.stanza(stanza.element))
    }

    /// Sends an IQ and awaits the matching result response.
    /// Returns the result's child element, or `nil` for result IQs with no child.
    /// Throws ``XMPPStanzaError`` for IQ errors and ``XMPPClientError/timeout`` if no response arrives within `timeout`.
    public func sendIQ(_ iq: XMPPIQ, timeout: Duration = .seconds(30)) async throws -> XMLElement? {
        var iq = iq
        let stanzaID = iq.id ?? generateID()
        iq.id = stanzaID
        let expectedFrom = iq.to?.bareJID

        return try await withCheckedThrowingContinuation { continuation in
            for interceptor in interceptors {
                interceptor.processOutgoing(iq.element)
            }

            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.expirePendingIQ(id: stanzaID)
            }

            pendingIQs[stanzaID] = PendingIQ(
                continuation: continuation,
                expectedFrom: expectedFrom,
                timeoutTask: timeoutTask
            )

            Task { [connection] in
                do {
                    try await connection.send(XMPPStreamWriter.stanza(iq.element))
                } catch {
                    if let pending = self.pendingIQs.removeValue(forKey: stanzaID) {
                        pending.timeoutTask.cancel()
                        pending.continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func expirePendingIQ(id: String) {
        if let pending = pendingIQs.removeValue(forKey: id) {
            pending.continuation.resume(throwing: XMPPClientError.timeout)
        }
    }

    // MARK: - Private: Stream Negotiation

    private func openStream() async throws {
        let bareJID = "\(credentials.username)@\(domain)"
        try await connection.send(XMPPStreamWriter.streamOpening(to: domain, from: bareJID))
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

    /// Attempts to resume a previous SM session. Returns `true` if resumed.
    private func attemptSMResume(features: XMLElement, reader: EventReader) async throws -> Bool {
        guard let sm = modules[ObjectIdentifier(StreamManagementModule.self)] as? StreamManagementModule,
              sm.isResumable,
              features.child(named: "sm", namespace: XMPPNamespaces.sm) != nil else {
            return false
        }

        let resumeElement = sm.buildResumeElement()
        try await connection.send(XMPPStreamWriter.stanza(resumeElement))
        let response = try await reader.awaitStanza()
        let result = sm.processResumeResponse(response)

        switch result {
        case let .resumed(jid, retransmitQueue):
            for stanza in retransmitQueue {
                try await connection.send(XMPPStreamWriter.stanza(stanza))
            }
            log.notice("Stream resumed as \(jid)")
            connectedJIDLock.withLock { $0 = jid }
            state = .connected(jid)
            eventContinuation.yield(.streamResumed(jid))
            return true
        case .failed:
            log.info("Stream resumption failed, falling back to normal bind")
            return false
        }
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
            case let .continueWith(reply):
                try await connection.send(XMPPStreamWriter.stanza(reply))
            case .success:
                return
            case let .failure(error):
                let message = String(describing: error)
                eventContinuation.yield(.authenticationFailed(message))
                throw XMPPClientError.authenticationFailed(message)
            }
        }
    }

    // MARK: - Private: SASL2 Authentication

    private func authenticateSASL2(
        features: XMLElement,
        sasl2Features: SASL2Features,
        reader: EventReader
    ) async throws -> SASL2Authenticator.AuthResult {
        var authenticator = SASL2Authenticator()

        // Build inline payloads
        var inlinePayloads: [XMLElement] = []
        if sasl2Features.supportsBind2 {
            let hasSM = modules[ObjectIdentifier(StreamManagementModule.self)] != nil
            let hasCarbons = modules[ObjectIdentifier(CarbonsModule.self)] != nil
            inlinePayloads.append(buildBind2Request(
                enableSM: hasSM && sasl2Features.supportsSM,
                enableCarbons: hasCarbons
            ))
        }

        let authElement: XMLElement
        do {
            authElement = try authenticator.begin(
                features: features,
                authcid: credentials.username,
                password: credentials.password,
                inlinePayloads: inlinePayloads
            )
        } catch {
            let message = String(describing: error)
            eventContinuation.yield(.authenticationFailed(message))
            throw XMPPClientError.authenticationFailed(message)
        }

        try await connection.send(XMPPStreamWriter.stanza(authElement))

        // Drive the SASL2 exchange
        while true {
            let element = try await reader.awaitStanza()

            let response = authenticator.receive(element)
            switch response {
            case let .continueWith(reply):
                try await connection.send(XMPPStreamWriter.stanza(reply))
            case let .success(result):
                return result
            case let .failure(error):
                let message = String(describing: error)
                eventContinuation.yield(.authenticationFailed(message))
                throw XMPPClientError.authenticationFailed(message)
            }
        }
    }

    /// Processes inline feature results from Bind 2 (SM enabled, carbons, etc.).
    private func processBind2Results(_ authResult: SASL2Authenticator.AuthResult, requestedCarbons: Bool) {
        if let bound = authResult.bound {
            // SM was enabled inline — server echoes <enabled> inside <bound>
            if let smEnabled = bound.child(named: "enabled", namespace: XMPPNamespaces.sm),
               let sm = modules[ObjectIdentifier(StreamManagementModule.self)] as? StreamManagementModule {
                sm.processInlineEnabled(smEnabled)
            }
        }

        // Carbons are activated by inclusion in the bind request — server doesn't echo back
        if requestedCarbons,
           let carbons = modules[ObjectIdentifier(CarbonsModule.self)] as? CarbonsModule {
            carbons.markInlineEnabled()
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

    // MARK: - Private: Dispatch Loop

    private func startReader(reader: EventReader) {
        readerTask = Task { [weak self] in
            while let event = await reader.next() {
                guard let self else { return }
                await handleEvent(event)
            }
            await self?.handleStreamEnd()
        }
    }

    private func handleEvent(_ event: XMLStreamEvent) async {
        switch event {
        case .streamOpened:
            break
        case let .stanzaReceived(element):
            dispatchStanza(element)
        case .streamClosed:
            await cleanUp(reason: .streamError(nil, text: "Stream closed by server"))
        case let .error(error):
            await cleanUp(reason: .connectionLost(error.message))
        }
    }

    private func dispatchStanza(_ element: XMLElement) {
        // Stream errors arrive at depth 1 as <error> within the stream namespace.
        if element.name == "error" {
            let condition = XMPPStreamError.parse(from: element)
            let text = element.children.compactMap({ node -> String? in
                guard case let .element(child) = node,
                      child.name == "text",
                      child.namespace == XMPPNamespaces.streams else { return nil }
                return child.textContent
            }).first
            Task { await cleanUp(reason: .streamError(condition, text: text)) }
            return
        }

        // Run incoming interceptors first; if any consumes the stanza, stop.
        guard !interceptors.contains(where: { $0.processIncoming(element) }) else { return }

        switch element.name {
        case "message":
            dispatchMessage(element)
        case "presence":
            dispatchPresence(element)
        case "iq":
            dispatchIQ(element)
        default:
            break
        }
    }

    private func dispatchMessage(_ element: XMLElement) {
        let message = XMPPMessage(element: element)
        eventContinuation.yield(.messageReceived(message))
        for module in modules.values {
            try? module.handleMessage(message)
        }
    }

    private func dispatchPresence(_ element: XMLElement) {
        let presence = XMPPPresence(element: element)
        eventContinuation.yield(.presenceReceived(presence))
        for module in modules.values {
            try? module.handlePresence(presence)
        }
    }

    private func dispatchIQ(_ element: XMLElement) {
        let iq = XMPPIQ(element: element)
        if let stanzaID = iq.id, let pending = pendingIQs[stanzaID],
           pending.expectedFrom == nil || iq.from?.bareJID == pending.expectedFrom {
            pendingIQs.removeValue(forKey: stanzaID)
            pending.timeoutTask.cancel()
            if iq.isError {
                let stanzaError = XMPPStanzaError.parse(from: iq.element.child(named: "error"))
                    ?? XMPPStanzaError(errorType: .cancel, condition: .undefinedCondition)
                pending.continuation.resume(throwing: stanzaError)
            } else {
                pending.continuation.resume(returning: iq.childElement)
            }
            return
        }
        eventContinuation.yield(.iqReceived(iq))
        let handled = modules.values.contains { (try? $0.handleIQ(iq)) == true }
        // RFC 6120 §8.2.3: Reply service-unavailable for unhandled get/set IQs
        if !handled, iq.isGet || iq.isSet {
            replyServiceUnavailable(for: iq)
        }
    }

    private func replyServiceUnavailable(for iq: XMPPIQ) {
        guard let stanzaID = iq.id else { return }
        Task {
            var errorIQ = XMPPIQ(type: .error, id: stanzaID)
            if let from = iq.from { errorIQ.to = from }
            // RFC 6120 §8.3.1: Echo the original payload
            if let originalChild = iq.childElement { errorIQ.element.addChild(originalChild) }
            var error = XMLElement(name: "error", attributes: ["type": "cancel"])
            let condition = XMLElement(name: "service-unavailable", namespace: XMPPNamespaces.stanzas)
            error.addChild(condition)
            errorIQ.element.addChild(error)
            try? await self.send(errorIQ)
        }
    }

    private func handleStreamEnd() async {
        guard case .connected = state else { return }
        await cleanUp(reason: .connectionLost("Stream ended"))
    }

    // MARK: - Private: Cleanup

    private func cleanUp(reason: DisconnectReason) async {
        if case .disconnected = state { return }
        readerTask?.cancel()
        readerTask = nil

        for module in modules.values {
            await module.handleDisconnect()
        }

        state = .disconnected
        connectedJIDLock.withLock { $0 = nil }
        serverFeaturesLock.withLock { $0 = nil }
        tlsInfoLock.withLock { $0 = nil }

        for pending in pendingIQs.values {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: XMPPClientError.notConnected)
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
                generateID()
            },
            connectedJID: { [connectedJIDLock] in
                connectedJIDLock.withLock { $0 }
            },
            domain: domain,
            availableFeatures: { [featuresLock] in
                featuresLock.withLock { $0 }
            },
            sendElement: { [weak self] element in
                try await self?.connection.send(XMPPStreamWriter.stanza(element))
            },
            serverStreamFeatures: { [serverFeaturesLock] in
                serverFeaturesLock.withLock { $0 }
            }
        )
    }
}
