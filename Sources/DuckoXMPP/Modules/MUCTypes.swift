/// MUC affiliation per XEP-0045 §5.2.
public enum MUCAffiliation: String, Sendable, Hashable {
    case owner, admin, member, outcast, none
}

/// Controls history retrieval when joining a MUC room per XEP-0045 §7.1.16.
public enum RoomHistoryFetch: Sendable {
    /// Omit `<history>`, let the server decide.
    case initial
    /// Request messages since the given ISO 8601 timestamp.
    case since(String)
    /// Skip all history.
    case skip
}

/// An item from an affiliation list query (muc#admin).
public struct MUCAffiliationItem: Sendable {
    public let jid: BareJID
    public let affiliation: MUCAffiliation
    public let nickname: String?
    public let reason: String?

    public init(jid: BareJID, affiliation: MUCAffiliation, nickname: String? = nil, reason: String? = nil) {
        self.jid = jid
        self.affiliation = affiliation
        self.nickname = nickname
        self.reason = reason
    }

    /// Parses a `MUCAffiliationItem` from an `<item>` element in a muc#admin query result.
    public static func parse(_ item: XMLElement) -> MUCAffiliationItem? {
        guard let jidString = item.attribute("jid"),
              let jid = BareJID.parse(jidString),
              let affiliationStr = item.attribute("affiliation") else { return nil }

        let affiliation = MUCAffiliation(rawValue: affiliationStr) ?? .none
        let nickname = item.attribute("nick")
        let reason = item.child(named: "reason")?.textContent

        return MUCAffiliationItem(jid: jid, affiliation: affiliation, nickname: nickname, reason: reason)
    }
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
