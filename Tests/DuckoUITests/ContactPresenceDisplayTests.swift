import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCore
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

    @Test
    @MainActor
    func `resolve(for:) maps a subscribed contact's presence keyed by its JID`() async throws {
        let accountID = UUID()
        let service = PresenceService()
        try await seedPresence(.dnd, for: "bob@example.com", into: service, accountID: accountID)

        let bob = try makeContact(jid: "bob@example.com", subscription: .both, accountID: accountID)
        #expect(ContactPresenceDisplay.resolve(for: bob, presenceService: service) == .dnd)

        // A subscribed contact with no presence under its own JID reads offline — proof
        // the lookup is keyed per contact rather than handing back the same value.
        let carol = try makeContact(jid: "carol@example.com", subscription: .both, accountID: accountID)
        #expect(ContactPresenceDisplay.resolve(for: carol, presenceService: service) == .offline)
    }

    @Test
    @MainActor
    func `resolve(for:) reports pending from the contact's outstanding subscription ask`() throws {
        let contact = try makeContact(
            jid: "bob@example.com", subscription: .none, accountID: UUID(), ask: "subscribe"
        )
        #expect(ContactPresenceDisplay.resolve(for: contact, presenceService: PresenceService()) == .pending)
    }

    @MainActor
    private func seedPresence(
        _ show: XMPPPresence.Show, for jid: String, into service: PresenceService, accountID: UUID
    ) async throws {
        var presence = XMPPPresence(type: nil)
        presence.show = show
        let bareJID = try #require(BareJID.parse(jid))
        let from = try JID.full(#require(FullJID(bareJID: bareJID, resourcePart: "res")))
        await service.handleEvent(.presenceUpdated(from: from, presence: presence), accountID: accountID)
    }

    private func makeContact(
        jid: String, subscription: Contact.Subscription, accountID: UUID, ask: String? = nil
    ) throws -> Contact {
        try Contact(
            id: UUID(),
            accountID: accountID,
            jid: #require(BareJID.parse(jid)),
            subscription: subscription,
            ask: ask,
            groups: [],
            isBlocked: false,
            createdAt: Date()
        )
    }
}
