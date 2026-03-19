import os

private let log = Logger(subsystem: "com.ducko.xmpp", category: "oob")

/// Implements XEP-0066 Out-of-Band Data (IQ-based) — handles incoming
/// IQ-set file transfer offers and provides accept/reject API.
public final class OOBModule: XMPPModule, Sendable {
    private struct PendingOffer {
        let iqID: String
        let from: JID
        let originalQuery: XMLElement
    }

    private struct State {
        var context: ModuleContext?
        var pendingOffers: [String: PendingOffer] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    public var features: [String] {
        [XMPPNamespaces.oobIQ]
    }

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Lifecycle

    public func handleDisconnect() async {
        state.withLock { $0.pendingOffers.removeAll() }
    }

    // MARK: - IQ Handling

    public func handleIQ(_ iq: XMPPIQ) throws -> Bool {
        guard iq.isSet,
              let child = iq.childElement,
              child.name == "query",
              child.namespace == XMPPNamespaces.oobIQ else {
            return false
        }

        guard let stanzaID = iq.id,
              let from = iq.from,
              let url = child.child(named: "url")?.textContent,
              !url.isEmpty else {
            return false
        }

        let desc = child.child(named: "desc")?.textContent
        let context = state.withLock { s -> ModuleContext? in
            s.pendingOffers[stanzaID] = PendingOffer(iqID: stanzaID, from: from, originalQuery: child)
            return s.context
        }

        let offer = OOBIQOffer(id: stanzaID, from: from, url: url, desc: desc)
        context?.emitEvent(.oobIQOfferReceived(offer))
        log.info("OOB IQ offer received from \(from): \(url)")
        return true
    }

    // MARK: - Public API

    /// Accepts an OOB IQ offer by responding with an IQ result.
    public func acceptOffer(id: String) async throws {
        let (context, pending) = state.withLock { s in
            (s.context, s.pendingOffers.removeValue(forKey: id))
        }
        guard let context, let pending else { return }

        var result = XMPPIQ(type: .result, id: pending.iqID)
        result.to = pending.from
        try await context.sendStanza(result)
        log.info("Accepted OOB IQ offer \(id)")
    }

    /// Rejects an OOB IQ offer by responding with a not-acceptable error.
    public func rejectOffer(id: String) async throws {
        let (context, pending) = state.withLock { s in
            (s.context, s.pendingOffers.removeValue(forKey: id))
        }
        guard let context, let pending else { return }

        var errorIQ = XMPPIQ(type: .error, id: pending.iqID)
        errorIQ.to = pending.from
        errorIQ.element.addChild(pending.originalQuery)
        var error = XMLElement(name: "error", attributes: ["type": "modify"])
        let condition = XMLElement(name: "not-acceptable", namespace: XMPPNamespaces.stanzas)
        error.addChild(condition)
        errorIQ.element.addChild(error)
        try await context.sendStanza(errorIQ)
        log.info("Rejected OOB IQ offer \(id)")
    }
}
