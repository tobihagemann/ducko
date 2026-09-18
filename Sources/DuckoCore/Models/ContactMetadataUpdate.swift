import Foundation

public enum ContactMetadataUpdate: Sendable {
    case alias(String?)
    case lastSeen(Date)
    case blocked(Bool)
    case avatar(hash: String?, data: Data?)

    public func apply(to contact: inout Contact) {
        switch self {
        case let .alias(alias): contact.localAlias = alias
        case let .lastSeen(date): contact.lastSeen = date
        case let .blocked(blocked): contact.isBlocked = blocked
        case let .avatar(hash, data):
            contact.avatarHash = hash
            contact.avatarData = data
        }
    }
}
