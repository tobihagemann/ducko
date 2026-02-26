import Foundation
import DuckoXMPP

public struct Contact: Sendable, Identifiable {
    public var id: UUID
    public var accountID: UUID
    public var jid: BareJID
    public var name: String?
    public var localAlias: String?
    public var subscription: Subscription
    public var ask: String?
    public var groups: [String]
    public var avatarHash: String?
    public var avatarData: Data?
    public var isBlocked: Bool
    public var lastSeen: Date?
    public var createdAt: Date

    public enum Subscription: String, Sendable {
        case none, to, from, both
    }

    public init(
        id: UUID,
        accountID: UUID,
        jid: BareJID,
        name: String? = nil,
        localAlias: String? = nil,
        subscription: Subscription,
        ask: String? = nil,
        groups: [String],
        avatarHash: String? = nil,
        avatarData: Data? = nil,
        isBlocked: Bool,
        lastSeen: Date? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.accountID = accountID
        self.jid = jid
        self.name = name
        self.localAlias = localAlias
        self.subscription = subscription
        self.ask = ask
        self.groups = groups
        self.avatarHash = avatarHash
        self.avatarData = avatarData
        self.isBlocked = isBlocked
        self.lastSeen = lastSeen
        self.createdAt = createdAt
    }
}
