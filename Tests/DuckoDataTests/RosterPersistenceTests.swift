import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoData
@testable import DuckoXMPP

struct RosterPersistenceTests {
    private enum Failure: Error { case beforeSave }

    @Test
    func `failed roster save rolls back contents and version before another save and reopen`() async throws {
        try await withTemporaryDirectory { directory in
            let container = try ModelContainerFactory.makeContainer(at: directory)
            let store = SwiftDataPersistenceStore(modelContainer: container)
            let account = try Account(id: UUID(), jid: #require(BareJID.parse("alice@example.com")), isEnabled: true, connectOnLaunch: false, rosterVersion: "before", createdAt: Date())
            try await store.saveAccount(account)
            let jid = try #require(BareJID.parse("bob@example.com"))
            let original = Contact(id: UUID(), accountID: account.id, jid: jid, name: "Bob", localAlias: "My friend", subscription: .both, groups: ["Friends"], isBlocked: true, createdAt: Date())
            try await store.upsertContact(original)
            await store.setBeforeRosterSaveForTesting { throw Failure.beforeSave }

            await #expect(throws: Failure.beforeSave) {
                _ = try await store.applyRosterMutation(RosterMutation(accountID: account.id, contents: .snapshot([]), version: "failed"))
            }
            #expect(try await store.fetchAccounts().first?.rosterVersion == "before")
            #expect(try await store.fetchContacts(for: account.id).first?.id == original.id)

            await store.setBeforeRosterSaveForTesting(nil)
            var settings = account
            settings.displayName = "After rollback"
            settings.rosterVersion = "stale-settings-value"
            try await store.saveAccount(settings)
            let reopened = try SwiftDataPersistenceStore(modelContainer: ModelContainerFactory.makeContainer(at: directory))
            #expect(try await reopened.fetchAccounts().first?.rosterVersion == "before")
            #expect(try await reopened.fetchAccounts().first?.displayName == "After rollback")
            let contacts = try await reopened.fetchContacts(for: account.id)
            #expect(contacts.count == 1)
            #expect(contacts.first?.id == original.id)
            #expect(contacts.first?.localAlias == "My friend")
        }
    }

    @Test
    func `roster merge preserves local fields and nil version invalidates cache version`() async throws {
        let store = try SwiftDataPersistenceStore(modelContainer: ModelContainerFactory.makeContainer(inMemory: true))
        let account = try Account(id: UUID(), jid: #require(BareJID.parse("alice@example.com")), isEnabled: true, connectOnLaunch: false, rosterVersion: "cached", createdAt: Date())
        try await store.saveAccount(account)
        let jid = try #require(BareJID.parse("bob@example.com"))
        let original = Contact(id: UUID(), accountID: account.id, jid: jid, name: "Before", localAlias: "Alias", subscription: .none, groups: [], avatarHash: "hash", avatarData: Data([1]), isBlocked: true, lastSeen: Date(timeIntervalSince1970: 123), createdAt: Date(timeIntervalSince1970: 12))
        try await store.upsertContact(original)
        let changed = RosterItem(jid: jid, name: "After", subscription: .both, groups: ["Work"])

        let contacts = try await store.applyRosterMutation(RosterMutation(accountID: account.id, contents: .snapshot([.init(changed)]), version: nil))

        let contact = try #require(contacts.first)
        #expect(contact.id == original.id)
        #expect(contact.name == "After")
        #expect(contact.groups == ["Work"])
        #expect(contact.localAlias == original.localAlias)
        #expect(contact.avatarData == original.avatarData)
        #expect(contact.isBlocked)
        #expect(contact.createdAt == original.createdAt)
        #expect(contact.lastSeen == original.lastSeen)
        #expect(try await store.fetchAccounts().first?.rosterVersion == nil)
    }

    @Test(arguments: [false, true])
    func `metadata update cannot recreate a deleted or replaced contact`(readd: Bool) async throws {
        let store = try SwiftDataPersistenceStore(modelContainer: ModelContainerFactory.makeContainer(inMemory: true))
        let account = try Account(id: UUID(), jid: #require(BareJID.parse("alice@example.com")), isEnabled: true, connectOnLaunch: false, createdAt: Date())
        try await store.saveAccount(account)
        let item = try RosterMutation.Item(RosterItem(jid: #require(BareJID.parse("bob@example.com"))))
        let originalContacts = try await store.applyRosterMutation(RosterMutation(accountID: account.id, contents: .snapshot([item]), version: "one"))
        let original = try #require(originalContacts.first)
        _ = try await store.applyRosterMutation(RosterMutation(accountID: account.id, contents: .snapshot([]), version: "two"))
        if readd { _ = try await store.applyRosterMutation(RosterMutation(accountID: account.id, contents: .snapshot([item]), version: "three")) }

        for update in [ContactMetadataUpdate.alias("Stale"), .avatar(hash: "old", data: Data([9])), .lastSeen(Date()), .blocked(true)] {
            #expect(try await !store.updateContactIfExists(original.id, accountID: account.id, update: update))
        }
        let contacts = try await store.fetchContacts(for: account.id)
        #expect(contacts.count == (readd ? 1 : 0))
        #expect(!contacts.contains { $0.id == original.id })
        #expect(contacts.first?.localAlias == nil)
        #expect(contacts.first?.avatarHash == nil)
    }
}
