import os

private let log = Logger(subsystem: "com.ducko.xmpp", category: "blocking")

/// Manages the XMPP blocking command (XEP-0191) — block list retrieval, block/unblock contacts, and push notifications.
public final class BlockingModule: XMPPModule, Sendable {
    private struct State {
        var context: ModuleContext?
        var blockedJIDs: Set<BareJID> = []
    }

    private let state: OSAllocatedUnfairLock<State>

    public var features: [String] {
        [XMPPNamespaces.blocking]
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

        // Request block list
        var iq = XMPPIQ(type: .get, id: context.generateID())
        let blocklist = XMLElement(name: "blocklist", namespace: XMPPNamespaces.blocking)
        iq.element.addChild(blocklist)

        let result: XMLElement?
        do {
            result = try await context.sendIQ(iq)
        } catch is XMPPStanzaError {
            log.warning("Block list GET returned stanza error")
            return
        }

        guard let result else { return }

        let jids = result.children(named: "item").compactMap { element -> BareJID? in
            guard let jidStr = element.attribute("jid") else { return nil }
            return BareJID.parse(jidStr)
        }

        state.withLock { state in
            state.blockedJIDs = Set(jids)
        }

        log.info("Block list loaded: \(jids.count) items")
        context.emitEvent(.blockListLoaded(jids))
    }

    public func handleDisconnect() async {
        state.withLock { $0.blockedJIDs.removeAll() }
    }

    // MARK: - IQ Handling

    public func handleIQ(_ iq: XMPPIQ) throws {
        guard iq.isSet else { return }
        guard let child = iq.childElement else { return }

        let isBlock = child.name == "block" && child.namespace == XMPPNamespaces.blocking
        let isUnblock = child.name == "unblock" && child.namespace == XMPPNamespaces.blocking
        guard isBlock || isUnblock else { return }

        let context = state.withLock { $0.context }
        guard let context else { return }

        // XEP-0191 §3.4/3.6: Push must come from own bare JID or have no 'from'.
        if let from = iq.from {
            guard let connectedJID = context.connectedJID(),
                  from.bareJID == connectedJID.bareJID else {
                log.warning("Rejected blocking push from foreign JID: \(from)")
                return
            }
        }

        processBlockingPush(child: child, isBlock: isBlock, context: context)
        acknowledgePush(iq: iq, context: context)
    }

    private func processBlockingPush(child: XMLElement, isBlock: Bool, context: ModuleContext) {
        let jids = child.children(named: "item").compactMap { item -> BareJID? in
            guard let jidStr = item.attribute("jid") else { return nil }
            return BareJID.parse(jidStr)
        }

        // XEP-0191 §3.6: Empty <unblock/> clears the entire block list.
        if !isBlock, jids.isEmpty {
            let previouslyBlocked = state.withLock { state -> [BareJID] in
                let all = Array(state.blockedJIDs)
                state.blockedJIDs.removeAll()
                return all
            }
            for jid in previouslyBlocked {
                log.info("Contact unblocked: \(jid)")
                context.emitEvent(.contactUnblocked(jid))
            }
            return
        }

        state.withLock { state in
            for jid in jids {
                if isBlock {
                    state.blockedJIDs.insert(jid)
                } else {
                    state.blockedJIDs.remove(jid)
                }
            }
        }

        for jid in jids {
            if isBlock {
                log.info("Contact blocked: \(jid)")
                context.emitEvent(.contactBlocked(jid))
            } else {
                log.info("Contact unblocked: \(jid)")
                context.emitEvent(.contactUnblocked(jid))
            }
        }
    }

    private func acknowledgePush(iq: XMPPIQ, context: ModuleContext) {
        guard let stanzaID = iq.id else { return }
        Task {
            var result = XMPPIQ(type: .result, id: stanzaID)
            if let from = iq.from {
                result.to = .bare(from.bareJID)
            }
            do {
                try await context.sendStanza(result)
            } catch {
                log.warning("Failed to acknowledge blocking push: \(error)")
            }
        }
    }

    // MARK: - Public API

    /// Returns the current set of blocked JIDs.
    public var blockedJIDs: Set<BareJID> {
        state.withLock { $0.blockedJIDs }
    }

    /// Blocks a contact.
    public func blockContact(jid: BareJID) async throws {
        try await sendBlockingIQ(elementName: "block", jid: jid)
    }

    /// Unblocks a contact.
    public func unblockContact(jid: BareJID) async throws {
        try await sendBlockingIQ(elementName: "unblock", jid: jid)
    }

    private func sendBlockingIQ(elementName: String, jid: BareJID) async throws {
        guard let context = state.withLock({ $0.context }) else { return }

        var iq = XMPPIQ(type: .set, id: context.generateID())
        var element = XMLElement(name: elementName, namespace: XMPPNamespaces.blocking)
        let item = XMLElement(name: "item", attributes: ["jid": jid.description])
        element.addChild(item)
        iq.element.addChild(element)

        _ = try await context.sendIQ(iq)
    }
}
