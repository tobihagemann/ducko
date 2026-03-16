import os

private let log = Logger(subsystem: "com.ducko.xmpp", category: "disco")

/// Implements XEP-0030 Service Discovery — responds to incoming disco#info queries
/// and provides API for querying other entities.
public final class ServiceDiscoveryModule: XMPPModule, Sendable {
    // MARK: - Types

    /// A service discovery identity.
    public struct Identity: Hashable, Sendable {
        public let category: String
        public let type: String
        public let lang: String
        public let name: String?

        public init(category: String, type: String, lang: String = "", name: String? = nil) {
            self.category = category
            self.type = type
            self.lang = lang
            self.name = name
        }
    }

    /// Result of a disco#info query.
    public struct InfoResult: Sendable {
        public let identities: [Identity]
        public let features: Set<String>
        public let forms: [[DataFormField]]

        public init(identities: [Identity], features: Set<String>, forms: [[DataFormField]] = []) {
            self.identities = identities
            self.features = features
            self.forms = forms
        }
    }

    /// A single disco#items item.
    public struct Item: Sendable {
        public let jid: JID
        public let name: String?
    }

    // MARK: - State

    private struct State {
        var context: ModuleContext?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let identity: Identity

    public var features: [String] {
        [XMPPNamespaces.discoInfo, XMPPNamespaces.discoItems]
    }

    public init(identity: Identity = Identity(category: "client", type: "pc", name: "Ducko")) {
        self.identity = identity
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - IQ Handling

    public func handleIQ(_ iq: XMPPIQ) throws {
        guard iq.isGet, let query = iq.childElement else { return }

        if query.namespace == XMPPNamespaces.discoInfo {
            handleDiscoInfoGet(iq)
        } else if query.namespace == XMPPNamespaces.discoItems {
            handleDiscoItemsGet(iq)
        }
    }

    private func handleDiscoInfoGet(_ iq: XMPPIQ) {
        guard let context = state.withLock({ $0.context }),
              let stanzaID = iq.id else { return }

        Task {
            var result = XMPPIQ(type: .result, id: stanzaID)
            if let from = iq.from { result.to = from }

            var query = XMLElement(name: "query", namespace: XMPPNamespaces.discoInfo)

            // Add identity
            var identityElement = XMLElement(name: "identity")
            identityElement.setAttribute("category", value: identity.category)
            identityElement.setAttribute("type", value: identity.type)
            if !identity.lang.isEmpty {
                identityElement.setAttribute("xml:lang", value: identity.lang)
            }
            if let name = identity.name {
                identityElement.setAttribute("name", value: name)
            }
            query.addChild(identityElement)

            // Add all registered features
            let allFeatures = context.availableFeatures()
            for feature in allFeatures.sorted() {
                let featureElement = XMLElement(name: "feature", attributes: ["var": feature])
                query.addChild(featureElement)
            }

            result.element.addChild(query)
            do {
                try await context.sendStanza(result)
            } catch {
                log.warning("Failed to send disco#info response: \(error)")
            }
        }
    }

    private func handleDiscoItemsGet(_ iq: XMPPIQ) {
        guard let context = state.withLock({ $0.context }),
              let stanzaID = iq.id else { return }

        Task {
            var result = XMPPIQ(type: .result, id: stanzaID)
            if let from = iq.from { result.to = from }

            let query = XMLElement(name: "query", namespace: XMPPNamespaces.discoItems)
            result.element.addChild(query)
            do {
                try await context.sendStanza(result)
            } catch {
                log.warning("Failed to send disco#items response: \(error)")
            }
        }
    }

    // MARK: - Public API

    /// Queries a remote entity for its disco#info.
    public func queryInfo(for jid: JID, node: String? = nil) async throws -> InfoResult {
        guard let context = state.withLock({ $0.context }) else {
            throw ServiceDiscoveryError.notConnected
        }

        var iq = XMPPIQ(type: .get, to: jid, id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.discoInfo)
        if let node { query.setAttribute("node", value: node) }
        iq.element.addChild(query)

        guard let result = try await context.sendIQ(iq) else {
            return InfoResult(identities: [], features: [])
        }

        let identities = result.children(named: "identity").map { element in
            Identity(
                category: element.attribute("category") ?? "",
                type: element.attribute("type") ?? "",
                lang: element.attribute("xml:lang") ?? "",
                name: element.attribute("name")
            )
        }

        var features = Set<String>()
        for element in result.children(named: "feature") {
            if let featureVar = element.attribute("var") {
                features.insert(featureVar)
            }
        }

        let forms = result.children(named: "x")
            .filter { $0.namespace == XMPPNamespaces.dataForms }
            .map { parseDataForm($0) }

        return InfoResult(identities: identities, features: features, forms: forms)
    }

    /// Queries a remote entity for its disco#items.
    public func queryItems(for jid: JID, node: String? = nil) async throws -> [Item] {
        guard let context = state.withLock({ $0.context }) else {
            throw ServiceDiscoveryError.notConnected
        }

        var iq = XMPPIQ(type: .get, to: jid, id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.discoItems)
        if let node { query.setAttribute("node", value: node) }
        iq.element.addChild(query)

        guard let result = try await context.sendIQ(iq) else {
            return []
        }

        return result.children(named: "item").compactMap { element in
            guard let jidString = element.attribute("jid"),
                  let jid = JID.parse(jidString) else {
                return nil
            }
            return Item(jid: jid, name: element.attribute("name"))
        }
    }
}

/// Errors from the service discovery module.
enum ServiceDiscoveryError: Error {
    case notConnected
}
