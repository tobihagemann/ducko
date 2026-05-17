import DuckoXMPP

/// Re-export for DuckoUI which cannot import DuckoXMPP.
public typealias RoomFlag = DuckoXMPP.RoomFlag

public enum RoomRole: String, Sendable, Hashable {
    case moderator, participant, visitor, none
}

public enum RoomAffiliation: String, Sendable, Hashable {
    case owner, admin, member, outcast, none

    public var displayName: String {
        switch self {
        case .owner: "Owner"
        case .admin: "Admin"
        case .member: "Member"
        case .outcast: "Outcast"
        case .none: "Other"
        }
    }

    public var sortPriority: Int {
        switch self {
        case .owner: 0
        case .admin: 1
        case .member: 2
        case .none: 3
        case .outcast: 4
        }
    }
}

public struct RoomParticipant: Sendable, Identifiable, Hashable {
    public var id: String {
        nickname
    }

    public let nickname: String
    public let jidString: String?
    public let affiliation: RoomAffiliation
    public let role: RoomRole

    public init(nickname: String, jidString: String? = nil, affiliation: RoomAffiliation, role: RoomRole) {
        self.nickname = nickname
        self.jidString = jidString
        self.affiliation = affiliation
        self.role = role
    }
}

public struct RoomParticipantGroup: Sendable, Identifiable {
    public var id: RoomAffiliation {
        affiliation
    }

    public let affiliation: RoomAffiliation
    public let participants: [RoomParticipant]

    public init(affiliation: RoomAffiliation, participants: [RoomParticipant]) {
        self.affiliation = affiliation
        self.participants = participants
    }
}

public struct DiscoveredRoom: Sendable, Identifiable {
    public var id: String {
        jidString
    }

    public let jidString: String
    public let name: String?

    public init(jidString: String, name: String?) {
        self.jidString = jidString
        self.name = name
    }
}

public struct ChannelSearchResult: Sendable {
    public let channels: [SearchedChannel]
    public let hasMore: Bool
    public let lastCursor: String?

    public init(channels: [SearchedChannel], hasMore: Bool, lastCursor: String?) {
        self.channels = channels
        self.hasMore = hasMore
        self.lastCursor = lastCursor
    }
}

/// Bridge type for XEP-0433 channel search results — DuckoUI-safe (String JIDs).
public struct SearchedChannel: Sendable, Identifiable {
    public var id: String {
        jidString
    }

    public let jidString: String
    public let name: String?
    public let userCount: Int?
    public let isOpen: Bool?
    public let description: String?

    public init(jidString: String, name: String?, userCount: Int?, isOpen: Bool?, description: String?) {
        self.jidString = jidString
        self.name = name
        self.userCount = userCount
        self.isOpen = isOpen
        self.description = description
    }
}

/// Bridge type for `DataFormField` so DuckoUI can edit room config without importing DuckoXMPP.
public struct RoomConfigField: Sendable, Identifiable {
    public var id: String {
        variable
    }

    public let variable: String
    public let type: String?
    public let label: String?
    public var values: [String]
    public let options: [(label: String?, value: String)]

    /// Whether this field should be displayed to users (excludes FORM_TYPE and hidden fields).
    public var isUserEditable: Bool {
        variable != "FORM_TYPE" && type != "hidden"
    }

    /// User-facing label, falling back to the variable name.
    public var displayLabel: String {
        label ?? variable
    }

    public init(
        variable: String,
        type: String? = nil,
        label: String? = nil,
        values: [String] = [],
        options: [(label: String?, value: String)] = []
    ) {
        self.variable = variable
        self.type = type
        self.label = label
        self.values = values
        self.options = options
    }
}

/// Bridge type for `MUCAffiliationItem` so DuckoUI can manage affiliations without importing DuckoXMPP.
public struct RoomAffiliationItem: Sendable, Identifiable {
    public var id: String {
        jidString
    }

    public let jidString: String
    public let affiliation: RoomAffiliation
    public let nickname: String?
    public let reason: String?

    public init(jidString: String, affiliation: RoomAffiliation, nickname: String? = nil, reason: String? = nil) {
        self.jidString = jidString
        self.affiliation = affiliation
        self.nickname = nickname
        self.reason = reason
    }
}

public struct PendingRoomInvite: Sendable, Identifiable {
    public var id: String {
        roomJIDString + "|" + (fromJIDString ?? "")
    }

    public let roomJIDString: String
    public let fromJIDString: String?
    public let reason: String?
    public let password: String?
    public let isDirect: Bool

    public init(roomJIDString: String, fromJIDString: String?, reason: String?, password: String?, isDirect: Bool = false) {
        self.roomJIDString = roomJIDString
        self.fromJIDString = fromJIDString
        self.reason = reason
        self.password = password
        self.isDirect = isDirect
    }
}
