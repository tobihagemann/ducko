import DuckoCore
import Foundation

/// View-layer presence treatment that distinguishes a genuinely-offline contact
/// from one whose presence is unknown because we aren't subscribed to it. Derived
/// from the roster subscription state plus the last-applied presence — never stored
/// on the model (which would ripple a new case into every `PresenceStatus` switch).
enum ContactPresenceDisplay {
    case available
    case away
    case dnd
    case offline
    case unknown
    case pending

    /// Plain-language label. "Presence unknown" covers the not-subscribed case the
    /// redesign exists to disambiguate from a genuinely-offline contact.
    var label: String {
        switch self {
        case .available: "Available"
        case .away: "Away"
        case .dnd: "Do Not Disturb"
        case .offline: "Offline"
        case .unknown: "Presence unknown"
        case .pending: "Pending approval"
        }
    }

    /// The one place the per-contact presence-key choice lives, so call sites don't re-spell it.
    @MainActor
    static func resolve(for contact: Contact, presenceService: PresenceService) -> ContactPresenceDisplay {
        resolve(
            subscription: contact.subscription,
            presence: presenceService.contactPresences[contact.jid],
            isPending: contact.isPendingSubscription
        )
    }

    /// Account-scoped variant: reads the contact's presence under `accountID` so the same peer JID
    /// on two accounts resolves the right account's presence. Falls back to the merged map when
    /// `accountID` is nil (account-less/imported paths).
    @MainActor
    static func resolve(for contact: Contact, accountID: UUID?, presenceService: PresenceService) -> ContactPresenceDisplay {
        let presence = accountID.map { presenceService.presence(for: contact.jid, accountID: $0) }
            ?? presenceService.contactPresences[contact.jid]
        return resolve(
            subscription: contact.subscription,
            presence: presence,
            isPending: contact.isPendingSubscription
        )
    }

    static func resolve(
        subscription: Contact.Subscription,
        presence: PresenceService.PresenceStatus?,
        isPending: Bool
    ) -> ContactPresenceDisplay {
        if isPending { return .pending }
        switch subscription {
        case .none, .from: return .unknown
        case .to, .both: return resolve(presence: presence)
        }
    }

    /// Maps a known presence (own/local presence, or a subscribed peer's) into a
    /// display treatment — never `.unknown`/`.pending`, which derive from subscription.
    static func resolve(presence: PresenceService.PresenceStatus?) -> ContactPresenceDisplay {
        switch presence {
        case .available: .available
        case .away, .xa: .away
        case .dnd: .dnd
        case .offline, .none: .offline
        }
    }
}
