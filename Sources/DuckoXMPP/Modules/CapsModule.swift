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
              let ver = capsChild.attribute("ver") else {
            return
        }

        // Record the ver hash as pending (features will be populated on disco#info lookup)
        state.withLock { state in
            if !state.capsCache.keys.contains(ver) {
                state.capsCache[ver] = nil
            }
        }
    }

    // MARK: - Public API

    /// Returns cached features for a verification hash, if known.
    /// Returns `nil` if the hash is unknown or features haven't been fetched yet.
    public func cachedFeatures(for ver: String) -> Set<String>? {
        state.withLock { $0.capsCache[ver] ?? nil }
    }

    /// Stores features for a verification hash in the cache.
    public func cacheFeatures(_ features: Set<String>, for ver: String) {
        state.withLock { $0.capsCache[ver] = features }
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
