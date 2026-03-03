import os

private let log = Logger(subsystem: "com.ducko.xmpp", category: "jingle")

/// Implements XEP-0166 Jingle and XEP-0234 Jingle File Transfer —
/// handles session negotiation for peer-to-peer file transfers.
public final class JingleModule: XMPPModule, Sendable {
    // MARK: - Types

    /// Errors from the Jingle module.
    public enum JingleError: Error {
        case notConnected
        case sessionNotFound
        case noConnectedJID
    }

    // MARK: - State

    private struct State {
        var context: ModuleContext?
        var sessions: [String: JingleSession] = [:]
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
        let (sessions, context) = state.withLock { state -> ([String: JingleSession], ModuleContext?) in
            let sessions = state.sessions
            let context = state.context
            state.sessions.removeAll()
            return (sessions, context)
        }

        for sid in sessions.keys {
            context?.emitEvent(.jingleFileTransferFailed(sid: sid, reason: "disconnected"))
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
            handleSessionAccept(sid: sid)
        case .sessionTerminate:
            handleSessionTerminate(jingle, sid: sid, context: context)
        case .transportInfo, .transportReplace, .transportAccept, .transportReject, .sessionInfo:
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

    private func handleSessionAccept(sid: String) {
        state.withLock { $0.sessions[sid]?.state = .active }
    }

    private func handleSessionTerminate(_ jingle: XMLElement, sid: String, context: ModuleContext) {
        let removed = state.withLock { $0.sessions.removeValue(forKey: sid) }
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

    private func parseTerminateReason(_ jingle: XMLElement) -> JingleTerminateReason? {
        guard let reasonElement = jingle.child(named: "reason") else { return nil }
        for case let .element(child) in reasonElement.children {
            if let reason = JingleTerminateReason(rawValue: child.name) {
                return reason
            }
        }
        return nil
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

        let transport = JingleTransportDescription.socks5(SOCKS5Transport(sid: transportSID))
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
    }

    /// Declines a pending incoming file transfer.
    public func declineFileTransfer(sid: String) async throws {
        try await terminateSession(sid: sid, reason: .decline)
    }

    /// Terminates a Jingle session with the given reason.
    public func terminateSession(sid: String, reason: JingleTerminateReason) async throws {
        let (context, session) = state.withLock { state -> (ModuleContext?, JingleSession?) in
            let context = state.context
            let session = state.sessions.removeValue(forKey: sid)
            return (context, session)
        }
        guard let context else { throw JingleError.notConnected }
        guard let session else { throw JingleError.sessionNotFound }

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
}
