import DuckoCore
import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoUI

@MainActor
struct ContactInfoWindowStateTests {
    private static let accountID = UUID()

    /// Seeds one contact into the roster and returns a state loaded against it.
    private static func loadedState(
        jid: String = "bob@example.com",
        subscription: Contact.Subscription,
        ask: String? = nil,
        seed: Bool = true
    ) async throws -> ContactInfoWindowState {
        let store = MockPersistenceStore()
        if seed {
            let contact = try Contact(
                id: UUID(),
                accountID: accountID,
                jid: #require(BareJID.parse(jid)),
                subscription: subscription,
                ask: ask,
                groups: [],
                isBlocked: false,
                createdAt: Date()
            )
            try await store.upsertContact(contact)
        }
        let environment = AppEnvironment(
            store: store,
            transcripts: MockTranscriptStore(),
            credentialStore: NullCredentialStore()
        )
        try await environment.rosterService.loadContacts(for: accountID)

        let state = ContactInfoWindowState(
            ref: ContactInfoRef(accountID: accountID, jid: jid),
            environment: environment
        )
        await state.load()
        return state
    }

    @Test(arguments: [
        (Contact.Subscription.none, true),
        (.from, true),
        (.to, false),
        (.both, false)
    ])
    func `canRequestPresence is true only when we don't receive the contact's presence`(
        subscription: Contact.Subscription,
        expected: Bool
    ) async throws {
        let state = try await Self.loadedState(subscription: subscription)
        #expect(state.canRequestPresence == expected)
    }

    @Test func `canRequestPresence is true for a contact not in the roster`() async throws {
        let state = try await Self.loadedState(subscription: .both, seed: false)
        #expect(state.contact == nil)
        #expect(state.canRequestPresence)
    }

    @Test func `presenceDisplay is unknown for a contact whose presence we don't receive`() async throws {
        // subscription `from` means the peer sees us but we get no presence from them,
        // so the display is "presence unknown" rather than offline.
        let state = try await Self.loadedState(subscription: .from)
        #expect(state.presenceDisplay == .unknown)
    }

    @Test func `presenceDisplay is pending while a subscription request is outstanding`() async throws {
        let state = try await Self.loadedState(subscription: .none, ask: "subscribe")
        #expect(state.presenceDisplay == .pending)
    }

    @Test func `load surfaces a profile-fetch error when no client is connected`() async throws {
        // No account is connected, so the peer vCard fetch fails; load() must route the
        // failure into profileError and clear the loading flag rather than hang.
        let state = try await Self.loadedState(subscription: .both)
        #expect(state.profileError != nil)
        #expect(!state.isLoadingProfile)
    }
}
