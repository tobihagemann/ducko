import CryptoKit
import os

private let log = Logger(subsystem: "com.ducko.xmpp", category: "caps")

/// Implements XEP-0115 Entity Capabilities — advertises capabilities via presence
/// and caches capabilities by verification hash.
public final class CapsModule: XMPPModule, Sendable {
    private struct State {
        var context: ModuleContext?
        /// `nil` value means the hash was seen but features haven't been fetched yet.
        var capsCache: [String: Set<String>?] = [:]
        /// Maps bare JIDs to their advertised verification hash.
        var jidToVer: [BareJID: String] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>
    private let identity: ServiceDiscoveryModule.Identity
    private let node: String

    public var features: [String] {
        [XMPPNamespaces.caps]
    }

    public init(
        identity: ServiceDiscoveryModule.Identity = ServiceDiscoveryModule.Identity(category: "client", type: "pc", name: "Ducko"),
        node: String = "https://ducko.app"
    ) {
        self.identity = identity
        self.node = node
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Lifecycle

    public func handleConnect() async throws {
        guard let context = state.withLock({ $0.context }) else { return }

        let allFeatures = context.availableFeatures()
        let ver = Self.generateVerificationString(identities: [identity], features: allFeatures)

        var presence = XMPPPresence()
        let capsElement = XMLElement(
            name: "c",
            namespace: XMPPNamespaces.caps,
            attributes: [
                "hash": "sha-1",
                "node": node,
                "ver": ver
            ]
        )
        presence.element.addChild(capsElement)

        try await context.sendStanza(presence)
        log.info("Sent presence with caps ver=\(ver)")
    }

    // MARK: - Dispatch

    public func handlePresence(_ presence: XMPPPresence) throws {
        guard let capsChild = presence.element.child(named: "c", namespace: XMPPNamespaces.caps),
              let ver = capsChild.attribute("ver"),
              let from = presence.from else {
            return
        }

        let bareJID = from.bareJID
        let capNode = capsChild.attribute("node")

        let (needsQuery, context) = state.withLock { state -> (Bool, ModuleContext?) in
            state.jidToVer[bareJID] = ver
            if state.capsCache.keys.contains(ver) {
                return (false, nil)
            }
            state.capsCache[ver] = nil
            return (true, state.context)
        }

        if needsQuery, let context {
            queryDiscoInfo(from: from, ver: ver, node: capNode, context: context)
        }
    }

    private func queryDiscoInfo(from jid: JID, ver: String, node: String?, context: ModuleContext) {
        Task {
            do {
                let queryNode = node.map { "\($0)#\(ver)" }
                var iq = XMPPIQ(type: .get, to: jid, id: context.generateID())
                var query = XMLElement(name: "query", namespace: XMPPNamespaces.discoInfo)
                if let queryNode { query.setAttribute("node", value: queryNode) }
                iq.element.addChild(query)

                guard let result = try await context.sendIQ(iq) else { return }

                let identities = result.children(named: "identity").map { identity in
                    ServiceDiscoveryModule.Identity(
                        category: identity.attribute("category") ?? "",
                        type: identity.attribute("type") ?? "",
                        name: identity.attribute("name")
                    )
                }
                let features: Set<String> = Set(
                    result.children(named: "feature").compactMap({ $0.attribute("var") })
                )

                let computedVer = Self.generateVerificationString(identities: identities, features: features)
                guard computedVer == ver else {
                    log.warning("Caps hash mismatch for ver=\(ver), computed=\(computedVer)")
                    state.withLock { _ = $0.capsCache.removeValue(forKey: ver) }
                    return
                }

                state.withLock { $0.capsCache[ver] = features }
                let count = features.count
                log.info("Cached \(count) features for ver=\(ver)")
            } catch {
                let desc = error.localizedDescription
                log.warning("Disco#info query failed for \(jid): \(desc)")
            }
        }
    }

    // MARK: - Public API

    /// Stores features for a verification hash in the cache.
    func cacheFeatures(_ features: Set<String>, for ver: String) {
        state.withLock { $0.capsCache[ver] = features }
    }

    /// Returns whether a bare JID supports a given feature, based on cached caps.
    public func isFeatureSupported(_ feature: String, by bareJID: BareJID) -> Bool {
        state.withLock { state in
            guard let ver = state.jidToVer[bareJID],
                  let features = state.capsCache[ver] ?? nil else {
                return false
            }
            return features.contains(feature)
        }
    }

    // MARK: - Lifecycle: Disconnect

    public func handleDisconnect() async {
        state.withLock { $0.jidToVer.removeAll() }
    }

    // MARK: - Verification String

    /// Generates the XEP-0115 §5.1 verification string.
    ///
    /// Sorts identities by `category/type`, sorts features alphabetically,
    /// concatenates with `<` separators, SHA-1 hashes, and base64 encodes.
    public static func generateVerificationString(
        identities: [ServiceDiscoveryModule.Identity],
        features: Set<String>
    ) -> String {
        var parts: [String] = []

        // Sort identities by category then type
        let sortedIdentities = identities.sorted { lhs, rhs in
            if lhs.category != rhs.category { return lhs.category < rhs.category }
            return lhs.type < rhs.type
        }
        for identity in sortedIdentities {
            parts.append("\(identity.category)/\(identity.type)//\(identity.name ?? "")<")
        }

        // Sort features
        for feature in features.sorted() {
            parts.append("\(feature)<")
        }

        let input = parts.joined()
        let hash = Insecure.SHA1.hash(data: Array(input.utf8))
        return Base64.encode(Array(hash))
    }
}
