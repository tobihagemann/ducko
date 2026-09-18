import DuckoXMPP
import Foundation

public struct RosterMutation: Sendable {
    public struct Item: Sendable {
        public let jid: BareJID
        public let name: String?
        public let subscription: Contact.Subscription
        public let asksForSubscription: Bool
        public let groups: [String]
        public let isRemoval: Bool

        public init(_ item: RosterItem) {
            self.jid = item.jid
            self.name = item.name
            self.subscription = switch item.subscription {
            case .none, .remove: .none
            case .to: .to
            case .from: .from
            case .both: .both
            }
            self.asksForSubscription = item.ask
            self.groups = item.groups
            self.isRemoval = item.subscription == .remove
        }

        public func merging(into existing: Contact?, accountID: UUID) -> Contact {
            var contact = existing ?? Contact(id: UUID(), accountID: accountID, jid: jid, subscription: subscription, groups: groups, isBlocked: false, createdAt: Date())
            contact.name = name
            contact.subscription = subscription
            contact.ask = asksForSubscription ? "subscribe" : nil
            contact.groups = groups
            return contact
        }
    }

    public enum Contents: Sendable {
        case snapshot([Item])
        case delta(Item)
    }

    public let accountID: UUID
    public let contents: Contents
    public let version: String?

    public init(accountID: UUID, contents: Contents, version: String?) {
        self.accountID = accountID
        self.contents = contents
        self.version = version
    }
}
