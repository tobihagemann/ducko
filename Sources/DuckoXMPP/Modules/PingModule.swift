import os

private let log = Logger(subsystem: "com.ducko.xmpp", category: "ping")

/// Implements XEP-0199 XMPP Ping — responds to incoming pings and
/// sends periodic keepalive pings to the server.
public final class PingModule: XMPPModule, Sendable {
    private struct State {
        var context: ModuleContext?
        var keepAliveTask: Task<Void, Never>?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let pingInterval: Duration

    public var features: [String] {
        [XMPPNamespaces.ping]
    }

    public init(pingInterval: Duration = .seconds(300)) {
        self.pingInterval = pingInterval
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Lifecycle

    public func handleConnect() async throws {
        guard state.withLock({ $0.context }) != nil else { return }

        let interval = pingInterval
        let task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                let ctx = state.withLock { $0.context }
                guard let ctx else { return }
                do {
                    var pingIQ = XMPPIQ(type: .get, id: ctx.generateID())
                    let pingChild = XMLElement(name: "ping", namespace: XMPPNamespaces.ping)
                    pingIQ.element.addChild(pingChild)
                    _ = try await ctx.sendIQ(pingIQ)
                } catch {
                    // Timeout or disconnection — ignore, the keepalive loop continues
                    log.debug("Keepalive ping failed: \(error)")
                }
            }
        }

        state.withLock { $0.keepAliveTask = task }
    }

    public func handleResume() async throws {
        try await handleConnect()
    }

    public func handleDisconnect() async {
        let task = state.withLock { state -> Task<Void, Never>? in
            let task = state.keepAliveTask
            state.keepAliveTask = nil
            return task
        }
        task?.cancel()
    }

    // MARK: - IQ Handling

    public func handleIQ(_ iq: XMPPIQ) throws {
        guard iq.isGet,
              iq.childElement?.name == "ping",
              iq.childElement?.namespace == XMPPNamespaces.ping else {
            return
        }

        let context = state.withLock { $0.context }
        guard let context else { return }

        if let stanzaID = iq.id {
            Task {
                var result = XMPPIQ(type: .result, id: stanzaID)
                if let from = iq.from {
                    result.to = from
                }
                do {
                    try await context.sendStanza(result)
                } catch {
                    log.warning("Failed to respond to ping: \(error)")
                }
            }
        }
    }
}
