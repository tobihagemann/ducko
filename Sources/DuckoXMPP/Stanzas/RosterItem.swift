/// A single item in the XMPP roster (RFC 6121 §2).
public struct RosterItem: Hashable, Sendable {
    public let jid: BareJID
    public var name: String?
    public var subscription: Subscription
    public var ask: Bool
    public var approved: Bool
    public var groups: [String]

    public enum Subscription: String, Hashable, Sendable {
        case none
        case to
        case from
        case both
        case remove
    }

    public init(jid: BareJID, name: String? = nil, subscription: Subscription = .none, ask: Bool = false, approved: Bool = false, groups: [String] = []) {
        self.jid = jid
        self.name = name
        self.subscription = subscription
        self.ask = ask
        self.approved = approved
        self.groups = groups
    }

    // MARK: - Parsing

    /// Parses a `<item>` element from a roster query result.
    public static func parse(_ element: XMLElement) -> RosterItem? {
        guard element.name == "item",
              let jidString = element.attribute("jid"),
              let jid = BareJID.parse(jidString) else {
            return nil
        }

        let name = element.attribute("name")
        let subscription = element.attribute("subscription").flatMap(Subscription.init(rawValue:)) ?? .none
        let ask = element.attribute("ask") == "subscribe"
        let approved = element.attribute("approved") == "true"
        let groups = element.children(named: "group").compactMap(\.textContent)

        return RosterItem(jid: jid, name: name, subscription: subscription, ask: ask, approved: approved, groups: groups)
    }
}
