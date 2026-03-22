import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.roster")

/// Manages the XMPP roster (RFC 6121) — contact list, subscription management, and roster pushes.
public final class RosterModule: XMPPModule, Sendable {
    private struct State {
        var context: ModuleContext?
        var roster: [BareJID: RosterItem] = [:]
        var rosterVersionProvider: (@Sendable () -> String?)?
        var supportsPreApproval: Bool = false
    }

    private let state: OSAllocatedUnfairLock<State>

    public var features: [String] {
        [XMPPNamespaces.roster]
    }

    /// Sets a closure the service layer provides to return the persisted roster version on connect.
    public func setRosterVersionProvider(_ provider: (@Sendable () -> String?)?) {
        state.withLock { $0.rosterVersionProvider = provider }
    }

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Lifecycle

    public func handleConnect() async throws {
        guard let context = state.withLock({ $0.context }) else { return }

        // Check server feature support
        let serverFeatures = context.serverStreamFeatures()
        let supportsVersioning = serverFeatures?.child(named: "ver", namespace: XMPPNamespaces.rosterVersioning) != nil
        let supportsPreApproval = serverFeatures?.child(named: "sub", namespace: XMPPNamespaces.preApproval) != nil
        state.withLock { $0.supportsPreApproval = supportsPreApproval }
        if supportsPreApproval {
            log.info("Server supports subscription pre-approval")
        }

        // Request roster (with version if supported)
        var iq = XMPPIQ(type: .get, id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.roster)
        if supportsVersioning {
            let provider = state.withLock { $0.rosterVersionProvider }
            let ver = provider?() ?? ""
            query.setAttribute("ver", value: ver)
        }
        iq.element.addChild(query)

        let result: XMLElement?
        do {
            result = try await context.sendIQ(iq)
        } catch is XMPPStanzaError {
            log.warning("Roster GET returned stanza error")
            return
        }

        // Empty result (no <query> child) means roster is up-to-date — use cached roster
        guard let result else {
            log.info("Roster up-to-date, using cached version")
            context.emitEvent(.rosterLoaded([]))
            return
        }

        let items = result.children(named: "item").compactMap(RosterItem.parse)

        // Track version from roster result
        if let ver = result.attribute("ver") {
            context.emitEvent(.rosterVersionChanged(ver))
        }

        state.withLock { state in
            state.roster.removeAll()
            for item in items {
                state.roster[item.jid] = item
            }
        }

        log.info("Roster loaded: \(items.count) items")
        context.emitEvent(.rosterLoaded(items))
    }

    public func handleDisconnect() async {
        state.withLock {
            $0.roster.removeAll()
            $0.supportsPreApproval = false
        }
    }

    // MARK: - IQ Handling

    public func handleIQ(_ iq: XMPPIQ) throws -> Bool {
        guard iq.isSet,
              let query = iq.childElement,
              query.namespace == XMPPNamespaces.roster else {
            return false
        }

        let context = state.withLock { $0.context }
        guard let context else { return true }

        // RFC 6121 §2.1.6: Roster push must come from own bare JID or have no 'from'.
        if let from = iq.from {
            guard let connectedJID = context.connectedJID(),
                  from.bareJID == connectedJID.bareJID else {
                log.warning("Rejected roster push from foreign JID: \(from)")
                return true
            }
        }

        // Track version from roster push
        if let ver = query.attribute("ver") {
            context.emitEvent(.rosterVersionChanged(ver))
        }

        // Process roster push items
        for child in query.children(named: "item") {
            guard let item = RosterItem.parse(child) else { continue }

            state.withLock { state in
                if item.subscription == .remove {
                    state.roster.removeValue(forKey: item.jid)
                } else {
                    state.roster[item.jid] = item
                }
            }

            log.info("Roster push: \(item.jid) subscription=\(item.subscription.rawValue)")
            context.emitEvent(.rosterItemChanged(item))
        }

        acknowledgeRosterPush(iq: iq, context: context)
        return true
    }

    private func acknowledgeRosterPush(iq: XMPPIQ, context: ModuleContext) {
        guard let stanzaID = iq.id else { return }
        Task {
            var result = XMPPIQ(type: .result, id: stanzaID)
            if let from = iq.from {
                result.to = .bare(from.bareJID)
            }
            do {
                try await context.sendStanza(result)
            } catch {
                log.warning("Failed to acknowledge roster push: \(error)")
            }
        }
    }

    // MARK: - Public API

    /// Adds or updates a contact in the roster.
    public func addContact(jid: BareJID, name: String? = nil, groups: [String] = []) async throws {
        guard let context = state.withLock({ $0.context }) else { return }

        var iq = XMPPIQ(type: .set, id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.roster)
        var item = XMLElement(name: "item", attributes: ["jid": jid.description])
        if let name { item.setAttribute("name", value: name) }
        for group in groups {
            var groupElement = XMLElement(name: "group")
            groupElement.addText(group)
            item.addChild(groupElement)
        }
        query.addChild(item)
        iq.element.addChild(query)

        _ = try await context.sendIQ(iq)
    }

    /// Removes a contact from the roster.
    public func removeContact(jid: BareJID) async throws {
        guard let context = state.withLock({ $0.context }) else { return }

        var iq = XMPPIQ(type: .set, id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.roster)
        let item = XMLElement(name: "item", attributes: ["jid": jid.description, "subscription": "remove"])
        query.addChild(item)
        iq.element.addChild(query)

        _ = try await context.sendIQ(iq)
    }

    // MARK: - Subscription Management

    /// Sends a subscription request to the given JID.
    public func subscribe(to jid: BareJID) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        let presence = XMPPPresence(type: .subscribe, to: .bare(jid))
        try await context.sendStanza(presence)
    }

    /// Approves a subscription request from the given JID.
    public func approveSubscription(from jid: BareJID) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        let presence = XMPPPresence(type: .subscribed, to: .bare(jid))
        try await context.sendStanza(presence)
    }

    /// Denies a subscription request from the given JID.
    public func denySubscription(from jid: BareJID) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        let presence = XMPPPresence(type: .unsubscribed, to: .bare(jid))
        try await context.sendStanza(presence)
    }

    /// Unsubscribes from the given JID's presence.
    public func unsubscribe(from jid: BareJID) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        let presence = XMPPPresence(type: .unsubscribe, to: .bare(jid))
        try await context.sendStanza(presence)
    }

    /// Pre-approves a future subscription request (RFC 6121 §3.4).
    public func preApprove(jid: BareJID) async throws {
        let (context, supported) = state.withLock { ($0.context, $0.supportsPreApproval) }
        guard let context else { return }
        guard supported else {
            log.info("Server does not support pre-approval, skipping for \(jid)")
            return
        }
        let presence = XMPPPresence(type: .subscribed, to: .bare(jid))
        try await context.sendStanza(presence)
    }

    /// Whether the server advertises subscription pre-approval support (RFC 6121 §3.4).
    public var supportsPreApproval: Bool {
        state.withLock { $0.supportsPreApproval }
    }
}
