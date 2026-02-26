/// An XMPP `<presence>` stanza.
public struct XMPPPresence: XMPPStanza {
    public var element: XMLElement

    public init(element: XMLElement) {
        self.element = element
    }

    public init(type: PresenceType? = nil, to: JID? = nil, id: String? = nil) {
        var attributes: [String: String] = [:]
        if let type { attributes["type"] = type.rawValue }
        if let to { attributes["to"] = to.description }
        if let id { attributes["id"] = id }
        self.element = XMLElement(name: "presence", attributes: attributes)
    }

    // MARK: - Presence Type

    /// Presence type attribute. `nil` means available per RFC 6121.
    public enum PresenceType: String, Sendable {
        case unavailable
        case subscribe
        case subscribed
        case unsubscribe
        case unsubscribed
        case probe
        case error
    }

    public var presenceType: PresenceType? {
        get { type.flatMap(PresenceType.init(rawValue:)) }
        set { type = newValue?.rawValue }
    }

    // MARK: - Show

    public enum Show: String, Comparable, Sendable {
        case chat
        case away
        case xa
        case dnd

        private var sortOrder: Int {
            switch self {
            case .chat: 0
            case .away: 1
            case .xa: 2
            case .dnd: 3
            }
        }

        public static func < (lhs: Show, rhs: Show) -> Bool {
            lhs.sortOrder < rhs.sortOrder
        }
    }

    public var show: Show? {
        get { element.childText(named: "show").flatMap(Show.init(rawValue:)) }
        set { element.setChildText(named: "show", to: newValue?.rawValue) }
    }

    // MARK: - Status

    public var status: String? {
        get { element.childText(named: "status") }
        set { element.setChildText(named: "status", to: newValue) }
    }

    // MARK: - Priority

    public var priority: Int {
        get { element.childText(named: "priority").flatMap(Int.init) ?? 0 }
        set { element.setChildText(named: "priority", to: String(newValue)) }
    }
}
