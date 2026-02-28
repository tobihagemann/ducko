import os

private let log = Logger(subsystem: "com.ducko.xmpp", category: "presence")

/// Tracks presence for contacts and sends initial available presence on connect.
public final class PresenceModule: XMPPModule, Sendable {
    private struct State {
        var context: ModuleContext?
        /// Presence map keyed by bare JID → resource → presence.
        var presences: [BareJID: [String: XMPPPresence]] = [:]
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
        let presence = XMPPPresence()
        try await context.sendStanza(presence)
        log.info("Sent initial available presence")
    }

    public func handleDisconnect() async {
        state.withLock { $0.presences.removeAll() }
    }

    // MARK: - Dispatch

    public func handlePresence(_ presence: XMPPPresence) throws {
        guard let from = presence.from else { return }
        let context = state.withLock { $0.context }

        if presence.presenceType == .subscribe {
            log.info("Subscription request from \(from)")
            context?.emitEvent(.presenceSubscriptionRequest(from: from.bareJID))
            return
        }

        let bareJID = from.bareJID
        let resource: String = switch from {
        case let .full(fullJID): fullJID.resourcePart
        case .bare: ""
        }

        state.withLock { state in
            if presence.presenceType == .unavailable {
                state.presences[bareJID]?.removeValue(forKey: resource)
                if state.presences[bareJID]?.isEmpty == true {
                    state.presences.removeValue(forKey: bareJID)
                }
            } else if presence.presenceType == nil {
                // nil type means available
                state.presences[bareJID, default: [:]][resource] = presence
            }
        }

        context?.emitEvent(.presenceUpdated(from: from, presence: presence))
    }

    // MARK: - Public API

    /// Returns the presence for a specific full JID.
    public func presence(for fullJID: FullJID) -> XMPPPresence? {
        state.withLock { $0.presences[fullJID.bareJID]?[fullJID.resourcePart] }
    }

    /// Returns all known presences for a bare JID (one per resource).
    public func presences(for bareJID: BareJID) -> [XMPPPresence] {
        state.withLock { state in
            guard let resources = state.presences[bareJID] else { return [] }
            return Array(resources.values)
        }
    }

    /// Broadcasts a presence update to all contacts.
    public func broadcastPresence(show: XMPPPresence.Show? = nil, status: String? = nil, priority: Int? = nil) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var presence = XMPPPresence()
        presence.show = show
        presence.status = status
        if let priority { presence.priority = priority }
        try await context.sendStanza(presence)
    }
}
