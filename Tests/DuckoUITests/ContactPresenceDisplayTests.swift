import DuckoCore
import Testing
@testable import DuckoUI

struct ContactPresenceDisplayTests {
    @Test
    func `pending overrides subscription and presence`() {
        for subscription in [Contact.Subscription.none, .from, .to, .both] {
            let display = ContactPresenceDisplay.resolve(
                subscription: subscription, presence: .available, isPending: true
            )
            #expect(display == .pending)
        }
    }

    @Test(arguments: [Contact.Subscription.none, .from])
    func `not-subscribed subscriptions resolve to unknown`(subscription: Contact.Subscription) {
        // Even when a presence value is somehow present, none/from means we don't
        // genuinely receive this peer's presence — show the unknown ring.
        let withPresence = ContactPresenceDisplay.resolve(
            subscription: subscription, presence: .available, isPending: false
        )
        let withoutPresence = ContactPresenceDisplay.resolve(
            subscription: subscription, presence: nil, isPending: false
        )
        #expect(withPresence == .unknown)
        #expect(withoutPresence == .unknown)
    }

    @Test(arguments: [Contact.Subscription.to, .both])
    func `subscribed with no presence resolves to offline`(subscription: Contact.Subscription) {
        let display = ContactPresenceDisplay.resolve(
            subscription: subscription, presence: nil, isPending: false
        )
        #expect(display == .offline)
    }

    @Test(
        arguments: [
            (PresenceService.PresenceStatus.available, ContactPresenceDisplay.available),
            (.away, .away),
            (.xa, .away),
            (.dnd, .dnd),
            (.offline, .offline)
        ] as [(PresenceService.PresenceStatus, ContactPresenceDisplay)]
    )
    func `subscribed maps presence to its display treatment`(
        presence: PresenceService.PresenceStatus, expected: ContactPresenceDisplay
    ) {
        #expect(
            ContactPresenceDisplay.resolve(subscription: .both, presence: presence, isPending: false) == expected
        )
    }

    @Test
    func `known-presence convenience never yields unknown or pending`() {
        #expect(ContactPresenceDisplay.resolve(presence: nil) == .offline)
        #expect(ContactPresenceDisplay.resolve(presence: .available) == .available)
        #expect(ContactPresenceDisplay.resolve(presence: .xa) == .away)
    }
}
