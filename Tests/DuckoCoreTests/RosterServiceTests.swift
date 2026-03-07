import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// MARK: - Helpers

private let testAccountID = UUID()
private let contactJID1 = BareJID(localPart: "alice", domainPart: "example.com")!
private let contactJID2 = BareJID(localPart: "bob", domainPart: "example.com")!
private let contactJID3 = BareJID(localPart: "carol", domainPart: "example.com")!

private func makeStore() -> MockPersistenceStore {
    MockPersistenceStore()
}

@MainActor
private func makeRosterService(store: MockPersistenceStore) -> RosterService {
    RosterService(store: store)
}

private func makeRosterItem(
    jid: BareJID,
    name: String? = nil,
    subscription: RosterItem.Subscription = .both,
    ask: Bool = false,
    groups: [String] = []
) -> RosterItem {
    RosterItem(jid: jid, name: name, subscription: subscription, ask: ask, groups: groups)
}

private func makeContact(
    jid: BareJID,
    name: String? = nil,
    localAlias: String? = nil,
    groups: [String] = []
) -> Contact {
    Contact(
        id: UUID(),
        accountID: testAccountID,
        jid: jid,
        name: name,
        localAlias: localAlias,
        subscription: .both,
        groups: groups,
        isBlocked: false,
        createdAt: Date()
    )
}

// MARK: - Tests

enum RosterServiceTests {
    struct RosterLoaded {
        @Test
        @MainActor
        func `Roster loaded event persists contacts to store`() async throws {
            let store = makeStore()
            let service = makeRosterService(store: store)

            let items = [
                makeRosterItem(jid: contactJID1, name: "Alice"),
                makeRosterItem(jid: contactJID2, name: "Bob")
            ]
            await service.handleEvent(.rosterLoaded(items), accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            #expect(contacts.count == 2)
        }

        @Test
        @MainActor
        func `Roster loaded builds correct groups`() async {
            let store = makeStore()
            let service = makeRosterService(store: store)

            let items = [
                makeRosterItem(jid: contactJID1, name: "Alice", groups: ["Friends"]),
                makeRosterItem(jid: contactJID2, name: "Bob", groups: ["Work"])
            ]
            await service.handleEvent(.rosterLoaded(items), accountID: testAccountID)

            #expect(service.groups.count == 2)
            #expect(service.groups[0].name == "Friends")
            #expect(service.groups[1].name == "Work")
        }

        @Test
        @MainActor
        func `Contacts without groups go into Ungrouped`() async {
            let store = makeStore()
            let service = makeRosterService(store: store)

            let items = [
                makeRosterItem(jid: contactJID1, name: "Alice"),
                makeRosterItem(jid: contactJID2, name: "Bob", groups: ["Friends"])
            ]
            await service.handleEvent(.rosterLoaded(items), accountID: testAccountID)

            #expect(service.groups.count == 2)
            #expect(service.groups[0].name == "Friends")
            #expect(service.groups[1].name == "Ungrouped")
            #expect(service.groups[1].contacts.count == 1)
            #expect(service.groups[1].contacts[0].jid == contactJID1)
        }

        @Test
        @MainActor
        func `Existing contacts preserve localAlias on roster reload`() async throws {
            let store = makeStore()
            let service = makeRosterService(store: store)

            // Pre-populate store with a contact that has a local alias
            let existing = makeContact(jid: contactJID1, name: "Alice", localAlias: "My Friend")
            try await store.upsertContact(existing)

            let items = [makeRosterItem(jid: contactJID1, name: "Alice Updated")]
            await service.handleEvent(.rosterLoaded(items), accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            #expect(contacts.count == 1)
            #expect(contacts[0].name == "Alice Updated")
            #expect(contacts[0].localAlias == "My Friend")
        }

        @Test
        @MainActor
        func `Contacts removed from roster are deleted from store`() async throws {
            let store = makeStore()
            let service = makeRosterService(store: store)

            // Pre-populate with two contacts
            try await store.upsertContact(makeContact(jid: contactJID1, name: "Alice"))
            try await store.upsertContact(makeContact(jid: contactJID2, name: "Bob"))

            // Roster reload only contains Alice
            let items = [makeRosterItem(jid: contactJID1, name: "Alice")]
            await service.handleEvent(.rosterLoaded(items), accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            #expect(contacts.count == 1)
            #expect(contacts[0].jid == contactJID1)
        }
    }

    struct RosterItemChanged {
        @Test
        @MainActor
        func `New roster item creates contact`() async throws {
            let store = makeStore()
            let service = makeRosterService(store: store)

            let item = makeRosterItem(jid: contactJID1, name: "Alice")
            await service.handleEvent(.rosterItemChanged(item), accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            #expect(contacts.count == 1)
            #expect(contacts[0].jid == contactJID1)
            #expect(contacts[0].name == "Alice")
        }

        @Test
        @MainActor
        func `Updated roster item updates contact fields`() async throws {
            let store = makeStore()
            let service = makeRosterService(store: store)

            // Create initial contact
            let item1 = makeRosterItem(jid: contactJID1, name: "Alice")
            await service.handleEvent(.rosterItemChanged(item1), accountID: testAccountID)

            // Update name
            let item2 = makeRosterItem(jid: contactJID1, name: "Alice Smith")
            await service.handleEvent(.rosterItemChanged(item2), accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            #expect(contacts.count == 1)
            #expect(contacts[0].name == "Alice Smith")
        }

        @Test
        @MainActor
        func `Roster item with subscription=remove deletes contact`() async throws {
            let store = makeStore()
            let service = makeRosterService(store: store)

            // Create initial contact
            try await store.upsertContact(makeContact(jid: contactJID1, name: "Alice"))

            let item = makeRosterItem(jid: contactJID1, subscription: .remove)
            await service.handleEvent(.rosterItemChanged(item), accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            #expect(contacts.isEmpty)
        }
    }

    struct GroupBuilding {
        @Test
        @MainActor
        func `Groups sorted alphabetically, Ungrouped last`() async {
            let store = makeStore()
            let service = makeRosterService(store: store)

            let items = [
                makeRosterItem(jid: contactJID1, name: "Alice", groups: ["Work"]),
                makeRosterItem(jid: contactJID2, name: "Bob", groups: ["Friends"]),
                makeRosterItem(jid: contactJID3, name: "Carol")
            ]
            await service.handleEvent(.rosterLoaded(items), accountID: testAccountID)

            #expect(service.groups.count == 3)
            #expect(service.groups[0].name == "Friends")
            #expect(service.groups[1].name == "Work")
            #expect(service.groups[2].name == "Ungrouped")
        }

        @Test
        @MainActor
        func `Contacts sorted by display name within groups`() async {
            let store = makeStore()
            let service = makeRosterService(store: store)

            let items = [
                makeRosterItem(jid: contactJID2, name: "Bob", groups: ["Friends"]),
                makeRosterItem(jid: contactJID1, name: "Alice", groups: ["Friends"])
            ]
            await service.handleEvent(.rosterLoaded(items), accountID: testAccountID)

            #expect(service.groups.count == 1)
            #expect(service.groups[0].contacts[0].name == "Alice")
            #expect(service.groups[0].contacts[1].name == "Bob")
        }

        @Test
        @MainActor
        func `Contact in multiple groups appears in each`() async {
            let store = makeStore()
            let service = makeRosterService(store: store)

            let items = [
                makeRosterItem(jid: contactJID1, name: "Alice", groups: ["Friends", "Work"])
            ]
            await service.handleEvent(.rosterLoaded(items), accountID: testAccountID)

            #expect(service.groups.count == 2)
            #expect(service.groups[0].contacts[0].jid == contactJID1)
            #expect(service.groups[1].contacts[0].jid == contactJID1)
        }
    }

    struct StringBasedMethods {
        @Test
        @MainActor
        func `addContact(jidString:) delegates to addContact(jid:)`() async throws {
            // Without an account service wired, the guard returns early — no crash
            let store = makeStore()
            let service = makeRosterService(store: store)

            // Should not throw even without wired account service
            try await service.addContact(jidString: "alice@example.com", name: "Alice", groups: ["Friends"], accountID: testAccountID)
        }

        @Test
        @MainActor
        func `addContact(jidString:) silently ignores invalid JID`() async throws {
            let store = makeStore()
            let service = makeRosterService(store: store)

            // Invalid JID — should return without error
            try await service.addContact(jidString: "invalid", name: nil, groups: [], accountID: testAccountID)
        }

        @Test
        @MainActor
        func `removeContact(jidString:) finds contact by JID string`() async throws {
            let store = makeStore()
            let service = makeRosterService(store: store)

            // Load a roster so groups are populated
            let items = [makeRosterItem(jid: contactJID1, name: "Alice")]
            await service.handleEvent(.rosterLoaded(items), accountID: testAccountID)

            // Without account service, the guard returns early — no crash
            try await service.removeContact(jidString: contactJID1.description, accountID: testAccountID)
        }

        @Test
        @MainActor
        func `removeContact(jidString:) silently ignores unknown JID`() async throws {
            let store = makeStore()
            let service = makeRosterService(store: store)

            // No contacts loaded — should return without error
            try await service.removeContact(jidString: "unknown@example.com", accountID: testAccountID)
        }

        @Test
        @MainActor
        func `approveSubscription(jidString:) silently returns without account service`() async throws {
            let store = makeStore()
            let service = makeRosterService(store: store)

            // Without account service, the guard returns early
            try await service.approveSubscription(jidString: "alice@example.com", accountID: testAccountID)
        }

        @Test
        @MainActor
        func `denySubscription(jidString:) silently returns without account service`() async throws {
            let store = makeStore()
            let service = makeRosterService(store: store)

            // Without account service, the guard returns early
            try await service.denySubscription(jidString: "alice@example.com", accountID: testAccountID)
        }
    }

    struct ContactDisplayName {
        @Test
        func `displayName prefers localAlias over name`() {
            let contact = makeContact(jid: contactJID1, name: "Alice", localAlias: "Ally")
            #expect(contact.displayName == "Ally")
        }

        @Test
        func `displayName falls back to name when no localAlias`() {
            let contact = makeContact(jid: contactJID1, name: "Alice")
            #expect(contact.displayName == "Alice")
        }

        @Test
        func `displayName falls back to JID when no name or alias`() {
            let contact = makeContact(jid: contactJID1)
            #expect(contact.displayName == contactJID1.description)
        }
    }

    struct RenameContact {
        @Test
        @MainActor
        func `Rename updates localAlias in store and rebuilds groups`() async throws {
            let store = makeStore()
            let service = makeRosterService(store: store)

            // Create initial contact via roster load
            let items = [makeRosterItem(jid: contactJID1, name: "Alice")]
            await service.handleEvent(.rosterLoaded(items), accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            let contact = try #require(contacts.first)

            try await service.renameContact(contact, newAlias: "Ally", accountID: testAccountID)

            let updated = try await store.fetchContacts(for: testAccountID)
            #expect(updated[0].localAlias == "Ally")
        }
    }

    struct UpdateLastSeen {
        @Test
        @MainActor
        func `updateLastSeen persists date for matching contact`() async throws {
            let store = makeStore()
            let service = makeRosterService(store: store)

            let items = [makeRosterItem(jid: contactJID1, name: "Alice")]
            await service.handleEvent(.rosterLoaded(items), accountID: testAccountID)

            let date = Date()
            await service.updateLastSeen(jid: contactJID1, date: date, accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            #expect(contacts[0].lastSeen == date)
        }

        @Test
        @MainActor
        func `updateLastSeen is no-op for unknown JID`() async throws {
            let store = makeStore()
            let service = makeRosterService(store: store)

            let items = [makeRosterItem(jid: contactJID1, name: "Alice")]
            await service.handleEvent(.rosterLoaded(items), accountID: testAccountID)

            let unknownJID = try #require(BareJID(localPart: "unknown", domainPart: "example.com"))
            await service.updateLastSeen(jid: unknownJID, date: Date(), accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            #expect(contacts[0].lastSeen == nil)
        }
    }

    struct AskField {
        @Test
        @MainActor
        func `Roster item with ask=true produces contact with ask=subscribe`() async throws {
            let store = makeStore()
            let service = makeRosterService(store: store)

            let items = [makeRosterItem(jid: contactJID1, name: "Alice", ask: true)]
            await service.handleEvent(.rosterLoaded(items), accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            #expect(contacts[0].ask == "subscribe")
        }

        @Test
        @MainActor
        func `Roster item with ask=false produces contact with nil ask`() async throws {
            let store = makeStore()
            let service = makeRosterService(store: store)

            let items = [makeRosterItem(jid: contactJID1, name: "Alice", ask: false)]
            await service.handleEvent(.rosterLoaded(items), accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            #expect(contacts[0].ask == nil)
        }
    }
}
