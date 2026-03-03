import os

private let log = Logger(subsystem: "com.ducko.xmpp", category: "jingle")

/// Implements XEP-0166 Jingle and XEP-0234 Jingle File Transfer —
/// handles session negotiation for peer-to-peer file transfers.
///
/// Also handles XEP-0260 SOCKS5 transport negotiation: discovers Proxy65
/// services, builds transport candidates, and orchestrates SOCKS5 connections.
public final class JingleModule: XMPPModule, Sendable {
    // MARK: - Types

    /// Errors from the Jingle module.
    public enum JingleError: Error {
        case notConnected
        case sessionNotFound
        case noConnectedJID
        case transportNegotiationFailed(String)
    }

    /// Discovered Proxy65 service info.
    private struct ProxyInfo: Sendable {
        let jid: String
        let host: String
        let port: UInt16
    }

    /// Snapshot of state extracted during disconnect cleanup.
    private struct DisconnectSnapshot {
        let sessions: [String: JingleSession]
        let context: ModuleContext?
        let connections: [SOCKS5Connection]
        let listeners: [SOCKS5Listener]
    }

    /// Snapshot of state extracted during session termination.
    private struct TerminateSnapshot {
        let context: ModuleContext?
        let session: JingleSession?
        let connection: SOCKS5Connection?
        let listener: SOCKS5Listener?
    }

    /// Sentinel CID for connections accepted by the local listener.
    private static let listenerCID = "direct-listener"

    // MARK: - State

    private struct State {
        var context: ModuleContext?
        var sessions: [String: JingleSession] = [:]
        var cachedProxy65: ProxyInfo?
        var activeConnections: [String: SOCKS5Connection] = [:]
        var activeListeners: [String: SOCKS5Listener] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    public var features: [String] {
        [XMPPNamespaces.jingle, XMPPNamespaces.jingleFileTransfer,
         XMPPNamespaces.jingleS5B, XMPPNamespaces.jingleIBB]
    }

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Lifecycle

    public func handleDisconnect() async {
        let snapshot = state.withLock { state -> DisconnectSnapshot in
            let snapshot = DisconnectSnapshot(
                sessions: state.sessions,
                context: state.context,
                connections: Array(state.activeConnections.values),
                listeners: Array(state.activeListeners.values)
            )
            state.sessions.removeAll()
            state.activeConnections.removeAll()
            state.activeListeners.removeAll()
            state.cachedProxy65 = nil
            return snapshot
        }

        for connection in snapshot.connections {
            await connection.close()
        }
        for listener in snapshot.listeners {
            await listener.close()
        }

        for sid in snapshot.sessions.keys {
            snapshot.context?.emitEvent(.jingleFileTransferFailed(sid: sid, reason: "disconnected"))
        }
    }

    // MARK: - IQ Handling

    public func handleIQ(_ iq: XMPPIQ) throws {
        guard iq.isSet,
              let jingle = iq.childElement,
              jingle.name == "jingle",
              jingle.namespace == XMPPNamespaces.jingle,
              let actionStr = jingle.attribute("action"),
              let action = JingleAction(rawValue: actionStr),
              let sid = jingle.attribute("sid") else {
            return
        }

        let context = state.withLock { $0.context }
        guard let context else { return }

        // Acknowledge IQ
        if let stanzaID = iq.id {
            Task {
                var result = XMPPIQ(type: .result, id: stanzaID)
                if let from = iq.from {
                    result.to = from
                }
                do {
                    try await context.sendStanza(result)
                } catch {
                    log.warning("Failed to acknowledge Jingle IQ: \(error)")
                }
            }
        }

        switch action {
        case .sessionInitiate:
            handleSessionInitiate(jingle, from: iq.from, sid: sid, context: context)
        case .sessionAccept:
            handleSessionAccept(sid: sid, context: context)
        case .sessionTerminate:
            handleSessionTerminate(jingle, sid: sid, context: context)
        case .transportInfo:
            handleTransportInfo(jingle, sid: sid, context: context)
        case .transportReplace, .transportAccept, .transportReject, .sessionInfo:
            break
        }
    }

    // MARK: - Action Handlers

    private func handleSessionInitiate(_ jingle: XMLElement, from: JID?, sid: String, context: ModuleContext) {
        guard let contentElement = jingle.child(named: "content"),
              let content = JingleContent(from: contentElement) else {
            log.warning("Invalid session-initiate: missing or malformed content")
            return
        }

        guard let from,
              case let .full(fullJID) = from else {
            log.warning("Invalid session-initiate: missing or bare from JID")
            return
        }

        let session = JingleSession(sid: sid, peer: fullJID, role: .responder, state: .pending, content: content)
        state.withLock { $0.sessions[sid] = session }

        let offer = JingleFileOffer(
            sid: sid,
            from: fullJID,
            fileName: content.description.name,
            fileSize: content.description.size,
            mediaType: content.description.mediaType
        )
        context.emitEvent(.jingleFileTransferReceived(offer))
    }

    private func handleSessionAccept(sid: String, context: ModuleContext) {
        state.withLock { $0.sessions[sid]?.state = .active }

        // Initiator begins transport connection after session-accept
        Task { await beginTransportConnection(sid: sid, context: context) }
    }

    private func handleSessionTerminate(_ jingle: XMLElement, sid: String, context: ModuleContext) {
        let removed = state.withLock { $0.sessions.removeValue(forKey: sid) }
        cleanupTransport(sid: sid)
        guard removed != nil else {
            log.debug("Ignoring session-terminate for unknown sid: \(sid)")
            return
        }

        let reason = parseTerminateReason(jingle)
        if reason == .success {
            context.emitEvent(.jingleFileTransferCompleted(sid: sid))
        } else {
            let reasonText = reason?.rawValue ?? "unknown"
            context.emitEvent(.jingleFileTransferFailed(sid: sid, reason: reasonText))
        }
    }

    private func handleTransportInfo(_ jingle: XMLElement, sid: String, context: ModuleContext) {
        let transportElement = extractTransportElement(from: jingle)
        guard let transportElement else {
            log.warning("transport-info without transport element for sid: \(sid)")
            return
        }

        if let candidateUsed = transportElement.child(named: "candidate-used"),
           let cid = candidateUsed.attribute("cid") {
            handleCandidateUsed(sid: sid, cid: cid, context: context)
        } else if transportElement.child(named: "candidate-error") != nil {
            handleCandidateError(sid: sid, context: context)
        }
    }

    private func handleCandidateUsed(sid: String, cid: String, context: ModuleContext) {
        let session = state.withLock { $0.sessions[sid] }
        guard let session else { return }

        // If we're the initiator and the peer selected a candidate, handle by type
        guard session.role == .initiator else { return }

        if case let .socks5(transport) = session.content.transport {
            let candidate = transport.candidates.first { $0.cid == cid }
            guard let candidate else { return }

            switch candidate.type {
            case .direct:
                // Direct candidate (our listener) — connection already established,
                // no activation needed. Clean up the listener.
                cleanupListener(sid: sid)
            case .proxy:
                Task {
                    do {
                        try await activateProxy(
                            proxyJID: candidate.jid,
                            targetJID: session.peer.description,
                            transportSID: transport.sid,
                            context: context
                        )
                    } catch {
                        log.warning("Proxy activation failed: \(error)")
                        context.emitEvent(.jingleFileTransferFailed(sid: sid, reason: "proxy-activation-failed"))
                    }
                }
            }
        }
    }

    private func handleCandidateError(sid: String, context: ModuleContext) {
        state.withLock { $0.sessions[sid]?.transportState = .failed }
        cleanupTransport(sid: sid)
        context.emitEvent(.jingleFileTransferFailed(sid: sid, reason: "candidate-error"))
    }

    private func parseTerminateReason(_ jingle: XMLElement) -> JingleTerminateReason? {
        guard let reasonElement = jingle.child(named: "reason") else { return nil }
        for case let .element(child) in reasonElement.children {
            if let reason = JingleTerminateReason(rawValue: child.name) {
                return reason
            }
        }
        return nil
    }

    private func extractTransportElement(from jingle: XMLElement) -> XMLElement? {
        // Try <content><transport> first, then <transport> directly under <jingle>
        if let content = jingle.child(named: "content"),
           let transport = content.child(named: "transport", namespace: XMPPNamespaces.jingleS5B) {
            return transport
        }
        return jingle.child(named: "transport", namespace: XMPPNamespaces.jingleS5B)
    }

    // MARK: - Public API

    /// Initiates a Jingle file transfer session with the given peer.
    /// Returns the session ID.
    public func initiateFileTransfer(to peer: FullJID, file: JingleFileDescription) async throws -> String {
        guard let context = state.withLock({ $0.context }) else {
            throw JingleError.notConnected
        }

        guard let myJID = context.connectedJID() else {
            throw JingleError.noConnectedJID
        }

        let sid = context.generateID()
        let transportSID = context.generateID()
        let candidates = await buildCandidates(context: context, sessionSID: sid, transportSID: transportSID)

        let transport = JingleTransportDescription.socks5(SOCKS5Transport(sid: transportSID, candidates: candidates))
        let content = JingleContent(
            name: "a-file-offer",
            creator: "initiator",
            description: file,
            transport: transport
        )

        let session = JingleSession(sid: sid, peer: peer, role: .initiator, state: .pending, content: content)
        state.withLock { $0.sessions[sid] = session }

        var iq = XMPPIQ(type: .set, to: .full(peer), id: context.generateID())
        var jingle = XMLElement(
            name: "jingle",
            namespace: XMPPNamespaces.jingle,
            attributes: [
                "action": JingleAction.sessionInitiate.rawValue,
                "initiator": myJID.description,
                "sid": sid
            ]
        )
        jingle.addChild(content.toXML())
        iq.element.addChild(jingle)

        try await context.sendStanza(iq)
        return sid
    }

    /// Accepts a pending incoming file transfer.
    public func acceptFileTransfer(sid: String) async throws {
        let (context, session) = state.withLock { state -> (ModuleContext?, JingleSession?) in
            let context = state.context
            guard let session = state.sessions[sid] else { return (context, nil) }
            state.sessions[sid]?.state = .active
            return (context, session)
        }
        guard let context else { throw JingleError.notConnected }
        guard let session else { throw JingleError.sessionNotFound }

        guard let myJID = context.connectedJID() else {
            throw JingleError.noConnectedJID
        }

        var iq = XMPPIQ(type: .set, to: .full(session.peer), id: context.generateID())
        var jingle = XMLElement(
            name: "jingle",
            namespace: XMPPNamespaces.jingle,
            attributes: [
                "action": JingleAction.sessionAccept.rawValue,
                "responder": myJID.description,
                "sid": sid
            ]
        )
        jingle.addChild(session.content.toXML())
        iq.element.addChild(jingle)

        try await context.sendStanza(iq)

        // Responder begins transport connection after sending session-accept
        Task { await beginTransportConnection(sid: sid, context: context) }
    }

    /// Declines a pending incoming file transfer.
    public func declineFileTransfer(sid: String) async throws {
        try await terminateSession(sid: sid, reason: .decline)
    }

    /// Terminates a Jingle session with the given reason.
    public func terminateSession(sid: String, reason: JingleTerminateReason) async throws {
        let snapshot = state.withLock { state -> TerminateSnapshot in
            TerminateSnapshot(
                context: state.context,
                session: state.sessions.removeValue(forKey: sid),
                connection: state.activeConnections.removeValue(forKey: sid),
                listener: state.activeListeners.removeValue(forKey: sid)
            )
        }
        guard let context = snapshot.context else { throw JingleError.notConnected }
        guard let session = snapshot.session else { throw JingleError.sessionNotFound }

        if let connection = snapshot.connection {
            await connection.close()
        }
        if let listener = snapshot.listener {
            await listener.close()
        }

        var iq = XMPPIQ(type: .set, to: .full(session.peer), id: context.generateID())
        var jingle = XMLElement(
            name: "jingle",
            namespace: XMPPNamespaces.jingle,
            attributes: [
                "action": JingleAction.sessionTerminate.rawValue,
                "sid": sid
            ]
        )

        var reasonElement = XMLElement(name: "reason")
        reasonElement.addChild(XMLElement(name: reason.rawValue))
        jingle.addChild(reasonElement)
        iq.element.addChild(jingle)

        try await context.sendStanza(iq)
    }

    // MARK: - File Data Transfer

    /// Sends file data over the SOCKS5 connection for a session.
    public func sendFileData(sid: String, data: [UInt8]) async throws {
        let (context, connection) = state.withLock { ($0.context, $0.activeConnections[sid]) }
        guard let context else { throw JingleError.notConnected }
        guard let connection else {
            throw JingleError.transportNegotiationFailed("No active connection for \(sid)")
        }

        let totalBytes = Int64(data.count)
        let chunkSize = 4096
        var offset = 0

        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = Array(data[offset ..< end])
            try await connection.send(chunk)
            offset = end
            let transferred = Int64(offset)
            context.emitEvent(.jingleFileTransferProgress(sid: sid, bytesTransferred: transferred, totalBytes: totalBytes))
        }

        try await terminateSession(sid: sid, reason: .success)
    }

    /// Receives file data over the SOCKS5 connection for a session.
    public func receiveFileData(sid: String, expectedSize: Int64) async throws -> [UInt8] {
        guard expectedSize > 0 else {
            throw JingleError.transportNegotiationFailed("Invalid file size: \(expectedSize)")
        }

        let (context, connection) = state.withLock { ($0.context, $0.activeConnections[sid]) }
        guard let context else { throw JingleError.notConnected }
        guard let connection else {
            throw JingleError.transportNegotiationFailed("No active connection for \(sid)")
        }

        var received: [UInt8] = []
        let chunkSize = 4096
        let total = Int(expectedSize)
        received.reserveCapacity(total)

        while received.count < total {
            let remaining = total - received.count
            let toRead = min(chunkSize, remaining)
            let chunk = try await connection.receive(toRead)
            received.append(contentsOf: chunk)
            let transferred = Int64(received.count)
            context.emitEvent(.jingleFileTransferProgress(sid: sid, bytesTransferred: transferred, totalBytes: expectedSize))
        }

        return received
    }

    // MARK: - Transport Connection Orchestration

    private func beginTransportConnection(sid: String, context: ModuleContext) async {
        let (session, listener) = state.withLock { state -> (JingleSession?, SOCKS5Listener?) in
            guard let session = state.sessions[sid] else { return (nil, nil) }
            state.sessions[sid]?.transportState = .connecting
            let listener = state.activeListeners[sid]
            return (session, listener)
        }
        guard let session else { return }

        let candidates = extractPeerCandidates(session: session)
        let dstAddr = computeDestinationAddress(session: session)
        let sorted = candidates.sorted { $0.priority > $1.priority }

        // Race outbound candidate connections against listener accept (if initiator)
        if let listener {
            defer { cleanupListener(sid: sid) }
            // Initiator waits for responder to connect to our listener
            if let result = await awaitListenerConnection(listener, dstAddr: dstAddr) {
                handleConnectionSuccess(sid: sid, result: result, session: session, context: context)
            } else {
                sendCandidateError(sid: sid, session: session, context: context)
            }
        } else if !candidates.isEmpty {
            // Responder — try outbound candidates only
            if let result = await tryConnectCandidates(sorted, dstAddr: dstAddr) {
                handleConnectionSuccess(sid: sid, result: result, session: session, context: context)
            } else {
                sendCandidateError(sid: sid, session: session, context: context)
            }
        } else {
            sendCandidateError(sid: sid, session: session, context: context)
        }
    }

    private func awaitListenerConnection(
        _ listener: SOCKS5Listener,
        dstAddr: String
    ) async -> (connection: SOCKS5Connection, cid: String)? {
        do {
            let connection = try await listener.accept(expectedDstAddr: dstAddr)
            return (connection, "direct-listener")
        } catch {
            log.debug("Listener accept failed: \(error)")
            return nil
        }
    }

    private func cleanupTransport(sid: String) {
        let (connection, listener) = state.withLock { state in
            let connection = state.activeConnections.removeValue(forKey: sid)
            let listener = state.activeListeners.removeValue(forKey: sid)
            return (connection, listener)
        }
        if let connection {
            Task { await connection.close() }
        }
        if let listener {
            Task { await listener.close() }
        }
    }

    private func cleanupListener(sid: String) {
        let listener = state.withLock { $0.activeListeners.removeValue(forKey: sid) }
        if let listener {
            Task { await listener.close() }
        }
    }

    private func extractPeerCandidates(session: JingleSession) -> [SOCKS5Transport.Candidate] {
        guard case let .socks5(transport) = session.content.transport else { return [] }
        return transport.candidates
    }

    private func computeDestinationAddress(session: JingleSession) -> String {
        guard case let .socks5(transport) = session.content.transport else { return "" }
        let myJID = state.withLock { $0.context?.connectedJID()?.description ?? "" }
        let initiatorJID: String
        let targetJID: String
        switch session.role {
        case .initiator:
            initiatorJID = myJID
            targetJID = session.peer.description
        case .responder:
            initiatorJID = session.peer.description
            targetJID = myJID
        }
        return SOCKS5Connection.destinationAddress(sid: transport.sid, initiatorJID: initiatorJID, targetJID: targetJID)
    }

    private func tryConnectCandidates(
        _ candidates: [SOCKS5Transport.Candidate],
        dstAddr: String
    ) async -> (connection: SOCKS5Connection, cid: String)? {
        for candidate in candidates {
            let connection = SOCKS5Connection()
            do {
                try await connection.connect(host: candidate.host, port: candidate.port, destinationAddress: dstAddr)
                return (connection, candidate.cid)
            } catch {
                log.debug("SOCKS5 candidate \(candidate.cid) failed: \(error)")
                await connection.close()
            }
        }
        return nil
    }

    private func handleConnectionSuccess(
        sid: String,
        result: (connection: SOCKS5Connection, cid: String),
        session: JingleSession,
        context: ModuleContext
    ) {
        let sessionExists = state.withLock { state -> Bool in
            guard state.sessions[sid] != nil else { return false }
            state.activeConnections[sid] = result.connection
            state.sessions[sid]?.transportState = .connected(candidateCID: result.cid)
            return true
        }
        guard sessionExists else {
            Task { await result.connection.close() }
            return
        }
        if result.cid != Self.listenerCID {
            sendCandidateUsed(sid: sid, cid: result.cid, session: session, context: context)
        }
    }

    private func sendCandidateUsed(sid: String, cid: String, session: JingleSession, context: ModuleContext) {
        sendTransportInfo(sid: sid, session: session, context: context,
                          transportChild: XMLElement(name: "candidate-used", attributes: ["cid": cid]))
    }

    private func sendCandidateError(sid: String, session: JingleSession, context: ModuleContext) {
        state.withLock { $0.sessions[sid]?.transportState = .failed }
        sendTransportInfo(sid: sid, session: session, context: context,
                          transportChild: XMLElement(name: "candidate-error"))
    }

    private func sendTransportInfo(sid: String, session: JingleSession, context: ModuleContext, transportChild: XMLElement) {
        guard case let .socks5(transport) = session.content.transport else { return }
        Task {
            var iq = XMPPIQ(type: .set, to: .full(session.peer), id: context.generateID())
            var jingle = XMLElement(
                name: "jingle",
                namespace: XMPPNamespaces.jingle,
                attributes: ["action": JingleAction.transportInfo.rawValue, "sid": sid]
            )
            var transportElement = XMLElement(name: "transport", namespace: XMPPNamespaces.jingleS5B, attributes: ["sid": transport.sid])
            transportElement.addChild(transportChild)
            var content = XMLElement(name: "content", attributes: ["creator": session.content.creator, "name": session.content.name])
            content.addChild(transportElement)
            jingle.addChild(content)
            iq.element.addChild(jingle)
            do {
                try await context.sendStanza(iq)
            } catch {
                log.warning("Failed to send transport-info: \(error)")
            }
        }
    }

    // MARK: - Proxy65 Discovery

    private func discoverProxy65(context: ModuleContext) async throws -> ProxyInfo? {
        let cached = state.withLock { $0.cachedProxy65 }
        if let cached { return cached }

        let items = try await queryDiscoItems(context: context)

        for item in items {
            let features = try? await queryDiscoFeatures(for: item, context: context)
            guard let features, features.contains(XMPPNamespaces.bytestreams) else { continue }

            if let proxy = try? await queryStreamhost(jid: item, context: context) {
                state.withLock { $0.cachedProxy65 = proxy }
                log.info("Discovered Proxy65: \(proxy.jid) at \(proxy.host):\(proxy.port)")
                return proxy
            }
        }

        return nil
    }

    private func queryDiscoItems(context: ModuleContext) async throws -> [String] {
        guard let domainJID = JID.parse(context.domain) else { return [] }

        var iq = XMPPIQ(type: .get, to: domainJID, id: context.generateID())
        let query = XMLElement(name: "query", namespace: XMPPNamespaces.discoItems)
        iq.element.addChild(query)

        guard let result = try await context.sendIQ(iq) else { return [] }

        return result.children(named: "item").compactMap { $0.attribute("jid") }
    }

    private func queryDiscoFeatures(for jid: String, context: ModuleContext) async throws -> Set<String> {
        guard let targetJID = JID.parse(jid) else { return [] }

        var iq = XMPPIQ(type: .get, to: targetJID, id: context.generateID())
        let query = XMLElement(name: "query", namespace: XMPPNamespaces.discoInfo)
        iq.element.addChild(query)

        guard let result = try await context.sendIQ(iq) else { return [] }

        return Set(result.children(named: "feature").compactMap { $0.attribute("var") })
    }

    private func queryStreamhost(jid: String, context: ModuleContext) async throws -> ProxyInfo? {
        guard let targetJID = JID.parse(jid) else { return nil }

        var iq = XMPPIQ(type: .get, to: targetJID, id: context.generateID())
        let query = XMLElement(name: "query", namespace: XMPPNamespaces.bytestreams)
        iq.element.addChild(query)

        guard let result = try await context.sendIQ(iq) else { return nil }

        guard let streamhost = result.child(named: "streamhost"),
              let host = streamhost.attribute("host"),
              let portStr = streamhost.attribute("port"),
              let port = UInt16(portStr) else { return nil }

        return ProxyInfo(jid: jid, host: host, port: port)
    }

    // MARK: - Candidate Building

    private func buildCandidates(
        context: ModuleContext,
        sessionSID: String,
        transportSID: String
    ) async -> [SOCKS5Transport.Candidate] {
        var candidates: [SOCKS5Transport.Candidate] = []

        // Direct candidates from local network interfaces
        let addresses = NetworkInterfaces.localAddresses().filter(\.isIPv4)
        if !addresses.isEmpty {
            let listener = SOCKS5Listener()
            if let port = try? await listener.start() {
                state.withLock { $0.activeListeners[sessionSID] = listener }

                let myJID = context.connectedJID()?.description ?? ""
                for (index, address) in addresses.enumerated() {
                    let candidate = SOCKS5Transport.Candidate(
                        cid: context.generateID(),
                        host: address.ip,
                        port: port,
                        jid: myJID,
                        priority: UInt32(100 + addresses.count - index),
                        type: .direct
                    )
                    candidates.append(candidate)
                }
            }
        }

        // Proxy candidate
        if let proxy = try? await discoverProxy65(context: context) {
            let candidate = SOCKS5Transport.Candidate(
                cid: context.generateID(),
                host: proxy.host,
                port: proxy.port,
                jid: proxy.jid,
                priority: 10,
                type: .proxy
            )
            candidates.append(candidate)
        }

        return candidates
    }

    // MARK: - Proxy Activation

    private func activateProxy(
        proxyJID: String,
        targetJID: String,
        transportSID: String,
        context: ModuleContext
    ) async throws {
        guard let proxyJ = JID.parse(proxyJID) else {
            throw JingleError.transportNegotiationFailed("Invalid proxy JID: \(proxyJID)")
        }

        var iq = XMPPIQ(type: .set, to: proxyJ, id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.bytestreams, attributes: ["sid": transportSID])
        var activate = XMLElement(name: "activate")
        activate.addText(targetJID)
        query.addChild(activate)
        iq.element.addChild(query)

        _ = try await context.sendIQ(iq)
    }
}
