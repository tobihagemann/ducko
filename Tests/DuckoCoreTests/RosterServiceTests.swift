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
    groups: [String] = []
) -> RosterItem {
    RosterItem(jid: jid, name: name, subscription: subscription, groups: groups)
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
        @Test("Roster loaded event persists contacts to store")
        @MainActor
        func rosterLoadedPersistsContacts() async throws {
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

        @Test("Roster loaded builds correct groups")
        @MainActor
        func rosterLoadedBuildsGroups() async {
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

        @Test("Contacts without groups go into Ungrouped")
        @MainActor
        func ungroupedContacts() async {
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

        @Test("Existing contacts preserve localAlias on roster reload")
        @MainActor
        func preservesLocalAlias() async throws {
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

        @Test("Contacts removed from roster are deleted from store")
        @MainActor
        func removesDeletedContacts() async throws {
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
        @Test("New roster item creates contact")
        @MainActor
        func newItemCreatesContact() async throws {
            let store = makeStore()
            let service = makeRosterService(store: store)

            let item = makeRosterItem(jid: contactJID1, name: "Alice")
            await service.handleEvent(.rosterItemChanged(item), accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            #expect(contacts.count == 1)
            #expect(contacts[0].jid == contactJID1)
            #expect(contacts[0].name == "Alice")
        }

        @Test("Updated roster item updates contact fields")
        @MainActor
        func updatedItemUpdatesFields() async throws {
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

        @Test("Roster item with subscription=remove deletes contact")
        @MainActor
        func removeSubscriptionDeletesContact() async throws {
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
        @Test("Groups sorted alphabetically, Ungrouped last")
        @MainActor
        func groupsSortedAlphabetically() async {
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

        @Test("Contacts sorted by display name within groups")
        @MainActor
        func contactsSortedByDisplayName() async {
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

        @Test("Contact in multiple groups appears in each")
        @MainActor
        func contactInMultipleGroups() async {
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

    struct ContactDisplayName {
        @Test("displayName prefers localAlias over name")
        func displayNamePrefersLocalAlias() {
            let contact = makeContact(jid: contactJID1, name: "Alice", localAlias: "Ally")
            #expect(contact.displayName == "Ally")
        }

        @Test("displayName falls back to name when no localAlias")
        func displayNameFallsBackToName() {
            let contact = makeContact(jid: contactJID1, name: "Alice")
            #expect(contact.displayName == "Alice")
        }

        @Test("displayName falls back to JID when no name or alias")
        func displayNameFallsBackToJID() {
            let contact = makeContact(jid: contactJID1)
            #expect(contact.displayName == contactJID1.description)
        }
    }

    struct RenameContact {
        @Test("Rename updates localAlias in store and rebuilds groups")
        @MainActor
        func renameUpdatesAlias() async throws {
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
}
