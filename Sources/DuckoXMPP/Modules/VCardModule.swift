import CryptoKit
import os

private let log = Logger(subsystem: "com.ducko.xmpp", category: "vcard")

/// Implements XEP-0054 vCard-temp — fetches and caches vCards.
public final class VCardModule: XMPPModule, Sendable {
    // MARK: - Types

    /// A parsed vCard-temp result.
    public struct VCard: Sendable {
        public let fullName: String?
        public let nickname: String?
        public let photoType: String?
        public let photoData: [UInt8]?
        public let photoHash: String?
    }

    // MARK: - State

    private struct State {
        var context: ModuleContext?
        var cache: [BareJID: VCard] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    public var features: [String] {
        [XMPPNamespaces.vcard]
    }

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Public API

    /// Fetches the vCard for a bare JID, using cache unless `forceRefresh` is true.
    public func fetchVCard(for jid: BareJID, forceRefresh: Bool = false) async throws -> VCard? {
        if !forceRefresh {
            if let cached = state.withLock({ $0.cache[jid] }) {
                return cached
            }
        }

        guard let context = state.withLock({ $0.context }) else { return nil }

        var iq = XMPPIQ(type: .get, to: .bare(jid), id: context.generateID())
        let vcardElement = XMLElement(name: "vCard", namespace: XMPPNamespaces.vcard)
        iq.element.addChild(vcardElement)

        guard let result = try await context.sendIQ(iq) else { return nil }

        let vcard = parseVCard(result)
        state.withLock { $0.cache[jid] = vcard }
        return vcard
    }

    /// Fetches the current user's own vCard.
    public func fetchOwnVCard(forceRefresh: Bool = false) async throws -> VCard? {
        guard let connectedJID = state.withLock({ $0.context })?.connectedJID() else { return nil }
        return try await fetchVCard(for: connectedJID.bareJID, forceRefresh: forceRefresh)
    }

    // MARK: - Parsing

    private func parseVCard(_ element: XMLElement) -> VCard {
        let fullName = element.childText(named: "FN")
        let nickname = element.childText(named: "NICKNAME")

        var photoType: String?
        var photoData: [UInt8]?
        var photoHash: String?

        if let photo = element.child(named: "PHOTO") {
            photoType = photo.childText(named: "TYPE")
            if let binval = photo.childText(named: "BINVAL"),
               let decoded = Base64.decode(binval) {
                photoData = decoded
                let hash = Insecure.SHA1.hash(data: decoded)
                photoHash = hash.map { String($0, radix: 16, uppercase: false).leftPadding(toLength: 2, withPad: "0") }.joined()
            }
        }

        return VCard(
            fullName: fullName,
            nickname: nickname,
            photoType: photoType,
            photoData: photoData,
            photoHash: photoHash
        )
    }
}

// MARK: - String Helpers

private extension String {
    func leftPadding(toLength length: Int, withPad pad: String) -> String {
        let deficit = length - count
        guard deficit > 0 else { return self }
        return String(repeating: pad, count: deficit) + self
    }
}
