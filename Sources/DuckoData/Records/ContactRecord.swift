import Foundation
import SwiftData

@Model
final class ContactRecord {
    @Attribute(.unique) var id: UUID
    var jid: String
    var name: String?
    var localAlias: String?
    var subscription: String
    var ask: String?
    var groups: [String]
    var avatarHash: String?
    @Attribute(.externalStorage) var avatarData: Data?
    var isBlocked: Bool
    var account: AccountRecord?
    var lastSeen: Date?
    var createdAt: Date

    init(
        id: UUID,
        jid: String,
        name: String? = nil,
        localAlias: String? = nil,
        subscription: String = "none",
        ask: String? = nil,
        groups: [String] = [],
        avatarHash: String? = nil,
        avatarData: Data? = nil,
        isBlocked: Bool = false,
        account: AccountRecord? = nil,
        lastSeen: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.jid = jid
        self.name = name
        self.localAlias = localAlias
        self.subscription = subscription
        self.ask = ask
        self.groups = groups
        self.avatarHash = avatarHash
        self.avatarData = avatarData
        self.isBlocked = isBlocked
        self.account = account
        self.lastSeen = lastSeen
        self.createdAt = createdAt
    }
}
