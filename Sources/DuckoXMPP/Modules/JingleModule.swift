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
    private struct ProxyInfo {
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

    /// Default block size for IBB transport (bytes per data chunk).
    private static let defaultIBBBlockSize = 4096

    // MARK: - State

    private struct State {
        var context: ModuleContext?
        var sessions: [String: JingleSession] = [:]
        var cachedProxy65: ProxyInfo?
        var activeConnections: [String: SOCKS5Connection] = [:]
        var activeListeners: [String: SOCKS5Listener] = [:]
        var ibbStates: [String: IBBSessionState] = [:]
        var ibbSIDToJingleSID: [String: String] = [:]
        var transportReadyContinuations: [String: CheckedContinuation<Void, Error>] = [:]
        var receiveDataContinuations: [String: CheckedContinuation<[UInt8], Error>] = [:]
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
        let (snapshot, transportContinuations, receiveContinuations) = state.withLock { state in
            let snapshot = DisconnectSnapshot(
                sessions: state.sessions,
                context: state.context,
                connections: Array(state.activeConnections.values),
                listeners: Array(state.activeListeners.values)
            )
            let transportConts = state.transportReadyContinuations
            let receiveConts = state.receiveDataContinuations
            state.sessions.removeAll()
            state.activeConnections.removeAll()
            state.activeListeners.removeAll()
            state.cachedProxy65 = nil
            state.ibbStates.removeAll()
            state.ibbSIDToJingleSID.removeAll()
            state.transportReadyContinuations.removeAll()
            state.receiveDataContinuations.removeAll()
            return (snapshot, transportConts, receiveConts)
        }

        for continuation in transportContinuations.values {
            continuation.resume(throwing: JingleError.notConnected)
        }
        for continuation in receiveContinuations.values {
            continuation.resume(throwing: JingleError.notConnected)
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
        guard iq.isSet, let child = iq.childElement else { return }

        if child.name == "jingle", child.namespace == XMPPNamespaces.jingle {
            handleJingleIQ(iq, jingle: child)
        } else if child.namespace == XMPPNamespaces.ibb {
            handleIBBIQ(iq, child: child)
        }
    }

    private func handleJingleIQ(_ iq: XMPPIQ, jingle: XMLElement) {
        guard let actionStr = jingle.attribute("action"),
              let action = JingleAction(rawValue: actionStr),
              let sid = jingle.attribute("sid") else { return }

        let context = state.withLock { $0.context }
        guard let context else { return }

        acknowledgeIQ(iq, context: context)

        switch action {
        case .sessionInitiate:
            handleSessionInitiate(jingle, from: iq.from, sid: sid, context: context)
        case .sessionAccept:
            handleSessionAccept(sid: sid, context: context)
        case .sessionTerminate:
            handleSessionTerminate(jingle, sid: sid, context: context)
        case .transportInfo:
            handleTransportInfo(jingle, sid: sid, context: context)
        case .transportReplace:
            handleTransportReplace(jingle, sid: sid, from: iq.from, context: context)
        case .transportAccept:
            handleTransportAccept(sid: sid)
        case .transportReject:
            handleTransportReject(sid: sid, context: context)
        case .sessionInfo:
            break
        }
    }

    private func acknowledgeIQ(_ iq: XMPPIQ, context: ModuleContext) {
        guard let stanzaID = iq.id else { return }
        Task {
            var result = XMPPIQ(type: .result, id: stanzaID)
            if let from = iq.from {
                result.to = from
            }
            do {
                try await context.sendStanza(result)
            } catch {
                log.warning("Failed to acknowledge IQ: \(error)")
            }
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

        let session = JingleSession(peer: fullJID, role: .responder, content: content)
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
        // Initiator begins transport connection after session-accept
        Task { await beginTransportConnection(sid: sid, context: context) }
    }

    private func handleSessionTerminate(_ jingle: XMLElement, sid: String, context: ModuleContext) {
        let (removed, continuations) = state.withLock { state -> (JingleSession?, SessionContinuations) in
            let session = state.sessions.removeValue(forKey: sid)
            let conts = cleanupSessionState(sid: sid, state: &state)
            return (session, conts)
        }
        cleanupTransport(sid: sid)

        continuations.cancel(with: JingleError.sessionNotFound)

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
        let session = state.withLock { state -> JingleSession? in
            state.sessions[sid]?.transportState = .failed
            return state.sessions[sid]
        }
        cleanupTransport(sid: sid)

        guard let session else {
            context.emitEvent(.jingleFileTransferFailed(sid: sid, reason: "candidate-error"))
            return
        }

        // Initiator proposes IBB fallback
        if session.role == .initiator {
            sendTransportReplace(sid: sid, session: session, context: context)
        } else {
            context.emitEvent(.jingleFileTransferFailed(sid: sid, reason: "candidate-error"))
        }
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
        if let content = jingle.child(named: "content") {
            if let transport = content.child(named: "transport", namespace: XMPPNamespaces.jingleS5B) {
                return transport
            }
            if let transport = content.child(named: "transport", namespace: XMPPNamespaces.jingleIBB) {
                return transport
            }
        }
        if let transport = jingle.child(named: "transport", namespace: XMPPNamespaces.jingleS5B) {
            return transport
        }
        return jingle.child(named: "transport", namespace: XMPPNamespaces.jingleIBB)
    }

    // MARK: - Transport Replace/Accept/Reject

    private func handleTransportReplace(_ jingle: XMLElement, sid: String, from: JID?, context: ModuleContext) {
        let transportElement = extractTransportElement(from: jingle)
        guard let transportElement,
              let ibbTransport = IBBTransport(from: transportElement) else {
            log.warning("transport-replace without valid IBB transport for sid: \(sid)")
            sendTransportReject(sid: sid, context: context)
            return
        }

        guard let from, case .full = from else {
            log.warning("transport-replace with invalid from JID")
            return
        }

        let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
            guard let session = state.sessions[sid] else { return nil }
            let ibbState = IBBSessionState(
                ibbSID: ibbTransport.sid,
                blockSize: ibbTransport.blockSize,
                expectedSize: session.content.description.size
            )
            state.ibbStates[sid] = ibbState
            state.ibbSIDToJingleSID[ibbTransport.sid] = sid
            state.sessions[sid]?.transportState = .pending
            return state.transportReadyContinuations.removeValue(forKey: sid)
        }

        sendTransportAccept(sid: sid, ibbTransport: ibbTransport, context: context)
        continuation?.resume()
    }

    private func handleTransportAccept(sid: String) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
            state.sessions[sid]?.transportState = .pending
            return state.transportReadyContinuations.removeValue(forKey: sid)
        }
        continuation?.resume()
    }

    private func handleTransportReject(sid: String, context: ModuleContext) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
            state.sessions[sid]?.transportState = .failed
            return state.transportReadyContinuations.removeValue(forKey: sid)
        }
        continuation?.resume(throwing: JingleError.transportNegotiationFailed("transport-reject"))
        context.emitEvent(.jingleFileTransferFailed(sid: sid, reason: "transport-reject"))
    }

    private func sendTransportReplace(sid: String, session: JingleSession, context: ModuleContext) {
        let ibbSID = context.generateID()
        let ibbTransport = IBBTransport(sid: ibbSID, blockSize: Self.defaultIBBBlockSize)

        state.withLock { state in
            state.sessions[sid]?.transportState = .replacePending
            let ibbState = IBBSessionState(
                ibbSID: ibbSID,
                blockSize: Self.defaultIBBBlockSize,
                expectedSize: session.content.description.size
            )
            state.ibbStates[sid] = ibbState
            state.ibbSIDToJingleSID[ibbSID] = sid
        }

        Task {
            var iq = XMPPIQ(type: .set, to: .full(session.peer), id: context.generateID())
            var jingle = XMLElement(
                name: "jingle",
                namespace: XMPPNamespaces.jingle,
                attributes: ["action": JingleAction.transportReplace.rawValue, "sid": sid]
            )
            var content = XMLElement(
                name: "content",
                attributes: ["creator": session.content.creator, "name": session.content.name]
            )
            content.addChild(ibbTransport.toXML())
            jingle.addChild(content)
            iq.element.addChild(jingle)
            do {
                try await context.sendStanza(iq)
            } catch {
                log.warning("Failed to send transport-replace: \(error)")
                context.emitEvent(.jingleFileTransferFailed(sid: sid, reason: "transport-replace-failed"))
            }
        }
    }

    private func sendTransportAccept(sid: String, ibbTransport: IBBTransport, context: ModuleContext) {
        let session = state.withLock { $0.sessions[sid] }
        guard let session else { return }
        Task {
            var iq = XMPPIQ(type: .set, to: .full(session.peer), id: context.generateID())
            var jingle = XMLElement(
                name: "jingle",
                namespace: XMPPNamespaces.jingle,
                attributes: ["action": JingleAction.transportAccept.rawValue, "sid": sid]
            )
            var content = XMLElement(
                name: "content",
                attributes: ["creator": session.content.creator, "name": session.content.name]
            )
            content.addChild(ibbTransport.toXML())
            jingle.addChild(content)
            iq.element.addChild(jingle)
            do {
                try await context.sendStanza(iq)
            } catch {
                log.warning("Failed to send transport-accept: \(error)")
            }
        }
    }

    private func sendTransportReject(sid: String, context: ModuleContext) {
        let session = state.withLock { $0.sessions[sid] }
        guard let session else { return }
        Task {
            var iq = XMPPIQ(type: .set, to: .full(session.peer), id: context.generateID())
            let jingle = XMLElement(
                name: "jingle",
                namespace: XMPPNamespaces.jingle,
                attributes: ["action": JingleAction.transportReject.rawValue, "sid": sid]
            )
            iq.element.addChild(jingle)
            do {
                try await context.sendStanza(iq)
            } catch {
                log.warning("Failed to send transport-reject: \(error)")
            }
        }
    }

    // MARK: - IBB IQ Handling

    private func handleIBBIQ(_ iq: XMPPIQ, child: XMLElement) {
        let context = state.withLock { $0.context }
        guard let context else { return }

        switch child.name {
        case "data":
            handleIBBData(iq, data: child, context: context)
        case "close":
            handleIBBClose(iq, context: context)
        default:
            break
        }
    }

    private func handleIBBData(_ iq: XMPPIQ, data element: XMLElement, context: ModuleContext) {
        guard let ibbSID = element.attribute("sid"),
              let seqStr = element.attribute("seq"),
              let seq = UInt16(seqStr),
              let base64Content = element.textContent else {
            return
        }

        acknowledgeIQ(iq, context: context)

        guard let decoded = Base64.decode(base64Content) else {
            log.warning("IBB data: invalid base64 for ibb-sid: \(ibbSID)")
            return
        }

        let (continuation, receivedData) = state.withLock { state -> (CheckedContinuation<[UInt8], Error>?, [UInt8]) in
            guard let jingleSID = state.ibbSIDToJingleSID[ibbSID],
                  var ibbState = state.ibbStates[jingleSID] else { return (nil, []) }

            guard seq == ibbState.nextExpectedSeq else {
                log.warning("IBB data: unexpected seq \(seq), expected \(ibbState.nextExpectedSeq)")
                return (nil, [])
            }

            ibbState.receivedData.append(contentsOf: decoded)
            ibbState.nextExpectedSeq &+= 1
            state.ibbStates[jingleSID] = ibbState

            let transferred = Int64(ibbState.receivedData.count)
            let total = ibbState.expectedSize
            context.emitEvent(.jingleFileTransferProgress(sid: jingleSID, bytesTransferred: transferred, totalBytes: total))

            if transferred >= total {
                let cont = state.receiveDataContinuations.removeValue(forKey: jingleSID)
                return (cont, ibbState.receivedData)
            }
            return (nil, [])
        }

        continuation?.resume(returning: receivedData)
    }

    private func handleIBBClose(_ iq: XMPPIQ, context: ModuleContext) {
        guard let child = iq.childElement,
              let ibbSID = child.attribute("sid") else { return }

        acknowledgeIQ(iq, context: context)

        let jingleSID = state.withLock { $0.ibbSIDToJingleSID[ibbSID] }
        guard let jingleSID else { return }

        let (continuation, data) = state.withLock { state -> (CheckedContinuation<[UInt8], Error>?, [UInt8]) in
            let receivedData = state.ibbStates[jingleSID]?.receivedData ?? []
            let cont = state.receiveDataContinuations.removeValue(forKey: jingleSID)
            state.ibbStates.removeValue(forKey: jingleSID)
            state.ibbSIDToJingleSID.removeValue(forKey: ibbSID)
            return (cont, receivedData)
        }

        continuation?.resume(returning: data)
        context.emitEvent(.jingleFileTransferCompleted(sid: jingleSID))
    }

    // MARK: - IBB State Cleanup

    /// Cleans up IBB state for a session. Must be called within a state.withLock.
    private func cleanupSessionState(sid: String, state: inout State) -> SessionContinuations {
        let transportCont = state.transportReadyContinuations.removeValue(forKey: sid)
        let receiveCont = state.receiveDataContinuations.removeValue(forKey: sid)
        if let ibbState = state.ibbStates.removeValue(forKey: sid) {
            state.ibbSIDToJingleSID.removeValue(forKey: ibbState.ibbSID)
        }
        return SessionContinuations(transport: transportCont, receive: receiveCont)
    }

    /// Holds continuations extracted during cleanup for cancellation outside the lock.
    private struct SessionContinuations {
        let transport: CheckedContinuation<Void, Error>?
        let receive: CheckedContinuation<[UInt8], Error>?

        func cancel(with error: Error) {
            transport?.resume(throwing: error)
            receive?.resume(throwing: error)
        }
    }

    // MARK: - Public API

    /// Waits until the transport is ready for data transfer (SOCKS5 connected or IBB established).
    public func awaitTransportReady(sid: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let alreadyReady = state.withLock { state -> Bool in
                if case .connected = state.sessions[sid]?.transportState { return true }
                if state.ibbStates[sid] != nil { return true }
                state.transportReadyContinuations[sid] = continuation
                return false
            }
            if alreadyReady { continuation.resume() }
        }
    }

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
        let candidates = await buildCandidates(context: context, sessionSID: sid)

        let transport = JingleTransportDescription.socks5(SOCKS5Transport(sid: transportSID, candidates: candidates))
        let content = JingleContent(
            name: "a-file-offer",
            creator: "initiator",
            description: file,
            transport: transport
        )

        let session = JingleSession(peer: peer, role: .initiator, content: content)
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
        let (snapshot, continuations) = state.withLock { state -> (TerminateSnapshot, SessionContinuations) in
            let conts = cleanupSessionState(sid: sid, state: &state)
            return (TerminateSnapshot(
                context: state.context,
                session: state.sessions.removeValue(forKey: sid),
                connection: state.activeConnections.removeValue(forKey: sid),
                listener: state.activeListeners.removeValue(forKey: sid)
            ), conts)
        }
        guard let context = snapshot.context else { throw JingleError.notConnected }
        guard let session = snapshot.session else { throw JingleError.sessionNotFound }

        continuations.cancel(with: JingleError.sessionNotFound)

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

    /// Sends file data over the established transport (SOCKS5 or IBB) for a session.
    public func sendFileData(sid: String, data: [UInt8]) async throws {
        let (context, connection, ibbState) = state.withLock {
            ($0.context, $0.activeConnections[sid], $0.ibbStates[sid])
        }
        guard let context else { throw JingleError.notConnected }

        if let connection {
            try await sendSOCKS5Data(sid: sid, data: data, connection: connection, context: context)
        } else if let ibbState {
            try await sendIBBData(sid: sid, data: data, ibbState: ibbState, context: context)
        } else {
            throw JingleError.transportNegotiationFailed("No active transport for \(sid)")
        }

        try await terminateSession(sid: sid, reason: .success)
    }

    private func sendSOCKS5Data(
        sid: String, data: [UInt8], connection: SOCKS5Connection, context: ModuleContext
    ) async throws {
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
    }

    private func sendIBBData(
        sid: String, data: [UInt8], ibbState: IBBSessionState, context: ModuleContext
    ) async throws {
        let session = state.withLock { $0.sessions[sid] }
        guard let session else { throw JingleError.sessionNotFound }

        let totalBytes = Int64(data.count)
        let blockSize = ibbState.blockSize
        var offset = 0
        var seq: UInt16 = 0

        while offset < data.count {
            let end = min(offset + blockSize, data.count)
            let chunk = Array(data[offset ..< end])
            try await sendIBBChunk(
                ibbSID: ibbState.ibbSID, seq: seq, chunk: chunk,
                peer: session.peer, context: context
            )
            offset = end
            seq &+= 1
            let transferred = Int64(offset)
            context.emitEvent(.jingleFileTransferProgress(sid: sid, bytesTransferred: transferred, totalBytes: totalBytes))
        }
    }

    private func sendIBBChunk(
        ibbSID: String, seq: UInt16, chunk: [UInt8],
        peer: FullJID, context: ModuleContext
    ) async throws {
        var iq = XMPPIQ(type: .set, to: .full(peer), id: context.generateID())
        var dataElement = XMLElement(
            name: "data",
            namespace: XMPPNamespaces.ibb,
            attributes: ["sid": ibbSID, "seq": String(seq)]
        )
        dataElement.addText(Base64.encode(chunk))
        iq.element.addChild(dataElement)
        _ = try await context.sendIQ(iq)
    }

    /// Receives file data over the established transport (SOCKS5 or IBB) for a session.
    public func receiveFileData(sid: String, expectedSize: Int64) async throws -> [UInt8] {
        guard expectedSize > 0 else {
            throw JingleError.transportNegotiationFailed("Invalid file size: \(expectedSize)")
        }

        let (context, connection, hasIBB) = state.withLock {
            ($0.context, $0.activeConnections[sid], $0.ibbStates[sid] != nil)
        }
        guard let context else { throw JingleError.notConnected }

        if let connection {
            return try await receiveSOCKS5Data(sid: sid, expectedSize: expectedSize, connection: connection, context: context)
        } else if hasIBB {
            return try await receiveIBBData(sid: sid)
        } else {
            throw JingleError.transportNegotiationFailed("No active transport for \(sid)")
        }
    }

    private func receiveSOCKS5Data(
        sid: String, expectedSize: Int64, connection: SOCKS5Connection, context: ModuleContext
    ) async throws -> [UInt8] {
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

    private func receiveIBBData(sid: String) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            let result = state.withLock { state -> (data: [UInt8]?, registered: Bool) in
                guard let ibbState = state.ibbStates[sid] else {
                    return (data: nil, registered: false)
                }
                let received = Int64(ibbState.receivedData.count)
                if received >= ibbState.expectedSize {
                    return (data: ibbState.receivedData, registered: false)
                }
                state.receiveDataContinuations[sid] = continuation
                return (data: nil, registered: true)
            }
            if let data = result.data {
                continuation.resume(returning: data)
            } else if !result.registered {
                continuation.resume(throwing: JingleError.transportNegotiationFailed("No IBB state for \(sid)"))
            }
        }
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
        let (sessionExists, continuation) = state.withLock { state -> (Bool, CheckedContinuation<Void, Error>?) in
            guard state.sessions[sid] != nil else { return (false, nil) }
            state.activeConnections[sid] = result.connection
            state.sessions[sid]?.transportState = .connected(candidateCID: result.cid)
            let cont = state.transportReadyContinuations.removeValue(forKey: sid)
            return (true, cont)
        }
        guard sessionExists else {
            Task { await result.connection.close() }
            return
        }
        continuation?.resume()
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
        sessionSID: String
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
