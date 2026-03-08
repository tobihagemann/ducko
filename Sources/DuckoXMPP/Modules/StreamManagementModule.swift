import os

private let log = Logger(subsystem: "com.ducko.xmpp", category: "sm")

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
        var resumptionID: String?
        var maxResumeSeconds: Int?
        var enableContinuation: CheckedContinuation<Void, any Error>?
    }

    private let state: OSAllocatedUnfairLock<State>

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
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
            state.incomingCounter = 0
            state.outgoingCounter = 0
            state.outgoingQueue.removeAll()
            state.resumptionID = nil
            state.maxResumeSeconds = nil
            return cont
        }
        continuation?.resume(throwing: XMPPClientError.notConnected)
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
                state.resumptionID = element.attribute("id")
                if let maxStr = element.attribute("max") {
                    state.maxResumeSeconds = Int(maxStr)
                }
                state.enabled = true
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
    }

    private func isStanza(_ element: XMLElement) -> Bool {
        element.name == "iq" || element.name == "message" || element.name == "presence"
    }
}
