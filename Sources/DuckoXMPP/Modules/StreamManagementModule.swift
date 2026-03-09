import os

private let log = Logger(subsystem: "com.ducko.xmpp", category: "sm")

/// State snapshot for resuming a Stream Management session across reconnects.
public struct SMResumeState: Sendable {
    public let resumptionId: String
    public let incomingCounter: UInt32
    public let outgoingCounter: UInt32
    public let outgoingQueue: [XMLElement]
    public let connectedJID: FullJID
    public let location: String?
}

/// Implements XEP-0198 Stream Management — tracks incoming/outgoing stanza
/// counts and enables reliable delivery via ack requests.
///
/// Must be registered as BOTH a module and an interceptor:
/// ```swift
/// let sm = StreamManagementModule()
/// builder.withModule(sm)
/// builder.withInterceptor(sm)
/// ```
public final class StreamManagementModule: XMPPModule, StanzaInterceptor, Sendable {
    private struct State {
        var context: ModuleContext?
        var enabled: Bool = false
        var incomingCounter: UInt32 = 0
        var outgoingCounter: UInt32 = 0
        var outgoingQueue: [XMLElement] = []
        var enableContinuation: CheckedContinuation<Void, any Error>?
        var resumptionId: String?
        var location: String?
        var connectedJID: FullJID?
    }

    /// Result of processing a `<resumed>` or `<failed>` response from the server.
    public enum ResumeResult: Sendable {
        case resumed(jid: FullJID, retransmitQueue: [XMLElement])
        case failed
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(previousState: SMResumeState? = nil) {
        if let previousState {
            var initial = State()
            initial.resumptionId = previousState.resumptionId
            initial.incomingCounter = previousState.incomingCounter
            initial.outgoingCounter = previousState.outgoingCounter
            initial.outgoingQueue = previousState.outgoingQueue
            initial.connectedJID = previousState.connectedJID
            initial.location = previousState.location
            self.state = OSAllocatedUnfairLock(initialState: initial)
        } else {
            self.state = OSAllocatedUnfairLock(initialState: State())
        }
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Public State Access

    /// Returns a snapshot of SM session state for resumption, or `nil` if not resumable.
    public nonisolated var resumeState: SMResumeState? {
        state.withLock { state in
            guard let resumptionId = state.resumptionId,
                  let connectedJID = state.connectedJID else { return nil }
            return SMResumeState(
                resumptionId: resumptionId,
                incomingCounter: state.incomingCounter,
                outgoingCounter: state.outgoingCounter,
                outgoingQueue: state.outgoingQueue,
                connectedJID: connectedJID,
                location: state.location
            )
        }
    }

    /// Whether this module has state that can be used to attempt stream resumption.
    public nonisolated var isResumable: Bool {
        state.withLock { $0.resumptionId != nil && $0.connectedJID != nil }
    }

    // MARK: - Lifecycle

    public func handleConnect() async throws {
        guard let context = state.withLock({ $0.context }) else { return }

        guard let features = context.serverStreamFeatures(),
              features.child(named: "sm", namespace: XMPPNamespaces.sm) != nil else {
            log.info("Server does not advertise Stream Management support")
            return
        }

        let enableElement = XMLElement(
            name: "enable",
            namespace: XMPPNamespaces.sm,
            attributes: ["resume": "true"]
        )

        do {
            try await withCheckedThrowingContinuation { cont in
                state.withLock { $0.enableContinuation = cont }
                Task {
                    do {
                        try await context.sendElement(enableElement)
                    } catch {
                        let pending = self.state.withLock { state -> CheckedContinuation<Void, any Error>? in
                            let c = state.enableContinuation
                            state.enableContinuation = nil
                            return c
                        }
                        pending?.resume(throwing: error)
                    }
                }
            }
        } catch {
            log.warning("Stream Management enable failed: \(error)")
        }
    }

    public func handleDisconnect() async {
        let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            let cont = state.enableContinuation
            state.enableContinuation = nil
            state.enabled = false
            // Preserve resume-related state across disconnect
            return cont
        }
        continuation?.resume(throwing: XMPPClientError.notConnected)
    }

    /// Clears all state including resume fields. Called on explicit disconnect or resume failure.
    public func resetResumption() {
        state.withLock { state in
            state.resumptionId = nil
            state.location = nil
            state.connectedJID = nil
            state.incomingCounter = 0
            state.outgoingCounter = 0
            state.outgoingQueue.removeAll()
            state.enabled = false
        }
    }

    // MARK: - Resume

    /// Builds a `<resume>` element for sending to the server during stream negotiation.
    public func buildResumeElement() -> XMLElement {
        let (previd, h) = state.withLock { (state: inout State) -> (String, UInt32) in
            (state.resumptionId ?? "", state.incomingCounter)
        }
        return XMLElement(
            name: "resume",
            namespace: XMPPNamespaces.sm,
            attributes: ["previd": previd, "h": String(h)]
        )
    }

    /// Processes a `<resumed>` or `<failed>` response from the server.
    public func processResumeResponse(_ element: XMLElement) -> ResumeResult {
        if element.name == "resumed", element.namespace == XMPPNamespaces.sm {
            return state.withLock { state in
                // Reconcile h-value: server tells us how many of our stanzas it received
                if let hStr = element.attribute("h"), let h = UInt32(hStr) {
                    Self.reconcileAck(h: h, state: &state)
                }

                let retransmitQueue = state.outgoingQueue
                guard let jid = state.connectedJID else {
                    return .failed
                }
                state.enabled = true
                return .resumed(jid: jid, retransmitQueue: retransmitQueue)
            }
        }

        // <failed> or unexpected element — reset resumption state
        resetResumption()
        return .failed
    }

    // MARK: - StanzaInterceptor

    public func processIncoming(_ element: XMLElement) -> Bool {
        if element.namespace == XMPPNamespaces.sm {
            handleSMElement(element)
            return true
        }

        if isStanza(element) {
            state.withLock { state in
                if state.enabled {
                    state.incomingCounter &+= 1
                }
            }
        }

        return false
    }

    public func processOutgoing(_ element: XMLElement) {
        if isStanza(element) {
            state.withLock { state in
                if state.enabled {
                    state.outgoingCounter &+= 1
                    state.outgoingQueue.append(element)
                }
            }
        }
    }

    // MARK: - Private

    private func handleSMElement(_ element: XMLElement) {
        switch element.name {
        case "enabled":
            let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                state.enabled = true
                state.resumptionId = element.attribute("id")
                state.location = element.attribute("location")
                if let context = state.context {
                    state.connectedJID = context.connectedJID()
                }
                let cont = state.enableContinuation
                state.enableContinuation = nil
                return cont
            }
            continuation?.resume()

        case "failed":
            let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                let cont = state.enableContinuation
                state.enableContinuation = nil
                return cont
            }
            continuation?.resume(throwing: XMPPClientError.unexpectedStreamState("SM enable failed"))

        case "r":
            let (counter, context) = state.withLock { (state: inout State) -> (UInt32, ModuleContext?) in
                (state.incomingCounter, state.context)
            }
            if let context {
                let a = XMLElement(
                    name: "a",
                    namespace: XMPPNamespaces.sm,
                    attributes: ["h": String(counter)]
                )
                Task { try? await context.sendElement(a) }
            }

        case "a":
            handleAck(element)

        default:
            break
        }
    }

    private func handleAck(_ element: XMLElement) {
        guard let hStr = element.attribute("h"), let h = UInt32(hStr) else { return }
        state.withLock { state in
            Self.reconcileAck(h: h, state: &state)
        }
    }

    private static func reconcileAck(h: UInt32, state: inout State) {
        let baseCounter = state.outgoingCounter &- UInt32(state.outgoingQueue.count)
        let acked = h &- baseCounter
        guard acked <= UInt32(state.outgoingQueue.count) else {
            let counter = state.outgoingCounter
            log.warning("Invalid ack h=\(h), expected at most \(counter)")
            return
        }
        let toRemove = Int(acked)
        if toRemove > 0 {
            state.outgoingQueue.removeFirst(toRemove)
        }
    }

    private func isStanza(_ element: XMLElement) -> Bool {
        element.name == "iq" || element.name == "message" || element.name == "presence"
    }
}
