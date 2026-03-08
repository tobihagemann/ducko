/// MUC affiliation per XEP-0045 §5.2.
public enum MUCAffiliation: String, Sendable, Hashable {
    case owner, admin, member, outcast, none
}

/// MUC role per XEP-0045 §5.1.
public enum MUCRole: String, Sendable, Hashable {
    case moderator, participant, visitor, none
}

/// An occupant in a MUC room.
public struct RoomOccupant: Sendable, Hashable {
    public let nickname: String
    public let jid: BareJID?
    public let affiliation: MUCAffiliation
    public let role: MUCRole

    public init(nickname: String, jid: BareJID? = nil, affiliation: MUCAffiliation, role: MUCRole) {
        self.nickname = nickname
        self.jid = jid
        self.affiliation = affiliation
        self.role = role
    }

    /// Parses a `RoomOccupant` from a `<item>` element inside `<x xmlns='muc#user'>`.
    public static func parse(_ item: XMLElement, nickname: String) -> RoomOccupant? {
        guard let affiliationStr = item.attribute("affiliation"),
              let roleStr = item.attribute("role") else { return nil }

        let affiliation = MUCAffiliation(rawValue: affiliationStr) ?? .none
        let role = MUCRole(rawValue: roleStr) ?? .none
        let jid = item.attribute("jid").flatMap { JID.parse($0)?.bareJID }

        return RoomOccupant(nickname: nickname, jid: jid, affiliation: affiliation, role: role)
    }
}

/// Snapshot of room state after joining.
public struct RoomOccupancy: Sendable {
    public let nickname: String
    public let occupants: [RoomOccupant]
    public let subject: String?

    public init(nickname: String, occupants: [RoomOccupant], subject: String?) {
        self.nickname = nickname
        self.occupants = occupants
        self.subject = subject
    }
}

/// A MUC room invitation.
public struct RoomInvite: Sendable {
    public let room: BareJID
    public let from: JID
    public let reason: String?
    public let password: String?

    public init(room: BareJID, from: JID, reason: String? = nil, password: String? = nil) {
        self.room = room
        self.from = from
        self.reason = reason
        self.password = password
    }
}
