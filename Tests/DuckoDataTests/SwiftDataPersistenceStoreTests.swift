import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoData
@testable import DuckoXMPP

struct SwiftDataPersistenceStoreTests {
    private func makeStore() throws -> SwiftDataPersistenceStore {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        return SwiftDataPersistenceStore(modelContainer: container)
    }

    private func makeAccount(
        id: UUID = UUID(),
        jid: String = "user@example.com",
        isEnabled: Bool = true,
        connectOnLaunch: Bool = false
    ) -> Account {
        Account(
            id: id,
            jid: BareJID.parse(jid)!,
            isEnabled: isEnabled,
            connectOnLaunch: connectOnLaunch,
            createdAt: Date()
        )
    }

    private func makeContact(
        id: UUID = UUID(),
        accountID: UUID,
        jid: String = "contact@example.com",
        groups: [String] = []
    ) -> Contact {
        Contact(
            id: id,
            accountID: accountID,
            jid: BareJID.parse(jid)!,
            subscription: .none,
            groups: groups,
            isBlocked: false,
            createdAt: Date()
        )
    }

    private func makeConversation(
        id: UUID = UUID(),
        accountID: UUID,
        jid: String = "contact@example.com",
        type: Conversation.ConversationType = .chat
    ) -> Conversation {
        Conversation(
            id: id,
            accountID: accountID,
            jid: BareJID.parse(jid)!,
            type: type,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            createdAt: Date()
        )
    }

    // MARK: - Accounts

    struct Accounts {
        private let outer = SwiftDataPersistenceStoreTests()

        @Test
        func `Save and fetch account`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()

            try await store.saveAccount(account)
            let fetched = try await store.fetchAccounts()

            #expect(fetched.count == 1)
            #expect(fetched.first?.id == account.id)
            #expect(fetched.first?.jid == account.jid)
        }

        @Test
        func `Update existing account`() async throws {
            let store = try outer.makeStore()
            var account = outer.makeAccount()
            try await store.saveAccount(account)

            account.displayName = "Updated"
            account.connectOnLaunch = true
            try await store.saveAccount(account)

            let fetched = try await store.fetchAccounts()
            #expect(fetched.count == 1)
            #expect(fetched.first?.displayName == "Updated")
            #expect(fetched.first?.connectOnLaunch == true)
        }

        @Test
        func `Delete account`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            try await store.deleteAccount(account.id)
            let fetched = try await store.fetchAccounts()
            #expect(fetched.isEmpty)
        }

        @Test
        func `Delete account nullifies relationships`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let contact = outer.makeContact(accountID: account.id)
            try await store.upsertContact(contact)

            let conversation = outer.makeConversation(accountID: account.id)
            try await store.upsertConversation(conversation)

            try await store.deleteAccount(account.id)

            // Records no longer associated with the deleted account
            let contacts = try await store.fetchContacts(for: account.id)
            let conversations = try await store.fetchConversations(for: account.id)
            #expect(contacts.isEmpty)
            #expect(conversations.isEmpty)

            // But conversation record still exists (nullified, not cascade-deleted)
            let allConversations = try await store.fetchAllConversations()
            #expect(allConversations.count == 1)
            #expect(allConversations.first?.accountID == nil)
        }
    }

    // MARK: - Contacts

    struct Contacts {
        private let outer = SwiftDataPersistenceStoreTests()

        @Test
        func `Upsert and fetch contacts by account`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let contact = outer.makeContact(accountID: account.id, jid: "alice@example.com")
            try await store.upsertContact(contact)

            let fetched = try await store.fetchContacts(for: account.id)
            #expect(fetched.count == 1)
            #expect(fetched.first?.jid.description == "alice@example.com")
        }

        @Test
        func `Update existing contact`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            var contact = outer.makeContact(accountID: account.id)
            try await store.upsertContact(contact)

            contact.name = "Alice"
            contact.subscription = .both
            try await store.upsertContact(contact)

            let fetched = try await store.fetchContacts(for: account.id)
            #expect(fetched.count == 1)
            #expect(fetched.first?.name == "Alice")
            #expect(fetched.first?.subscription == .both)
        }

        @Test
        func `Groups array round-trips`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let groups = ["Friends", "Work", "Family"]
            let contact = outer.makeContact(accountID: account.id, groups: groups)
            try await store.upsertContact(contact)

            let fetched = try await store.fetchContacts(for: account.id)
            #expect(fetched.first?.groups == groups)
        }

        @Test
        func `Fetch scoped to account`() async throws {
            let store = try outer.makeStore()
            let account1 = outer.makeAccount(jid: "user1@example.com")
            let account2 = outer.makeAccount(jid: "user2@example.com")
            try await store.saveAccount(account1)
            try await store.saveAccount(account2)

            let contact1 = outer.makeContact(accountID: account1.id, jid: "alice@example.com")
            let contact2 = outer.makeContact(accountID: account2.id, jid: "bob@example.com")
            try await store.upsertContact(contact1)
            try await store.upsertContact(contact2)

            let fetched1 = try await store.fetchContacts(for: account1.id)
            let fetched2 = try await store.fetchContacts(for: account2.id)
            #expect(fetched1.count == 1)
            #expect(fetched1.first?.jid.description == "alice@example.com")
            #expect(fetched2.count == 1)
            #expect(fetched2.first?.jid.description == "bob@example.com")
        }
    }

    // MARK: - Conversations

    struct Conversations {
        private let outer = SwiftDataPersistenceStoreTests()

        @Test
        func `Upsert and fetch conversations`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let conversation = outer.makeConversation(accountID: account.id)
            try await store.upsertConversation(conversation)

            let fetched = try await store.fetchConversations(for: account.id)
            #expect(fetched.count == 1)
            #expect(fetched.first?.id == conversation.id)
        }

        @Test(arguments: [
            Conversation.ConversationType.chat,
            Conversation.ConversationType.groupchat
        ])
        func `Conversation type round-trips`(type: Conversation.ConversationType) async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let conversation = outer.makeConversation(accountID: account.id, type: type)
            try await store.upsertConversation(conversation)

            let fetched = try await store.fetchConversations(for: account.id)
            #expect(fetched.first?.type == type)
        }

        @Test
        func `Last message date and preview update`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            var conversation = outer.makeConversation(accountID: account.id)
            try await store.upsertConversation(conversation)

            let now = Date()
            conversation.lastMessageDate = now
            conversation.lastMessagePreview = "Hello!"
            try await store.upsertConversation(conversation)

            let fetched = try await store.fetchConversations(for: account.id)
            #expect(fetched.first?.lastMessagePreview == "Hello!")
        }

        @Test
        func `Fetch single conversation by JID and type`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let chat = outer.makeConversation(accountID: account.id, jid: "alice@example.com", type: .chat)
            let room = outer.makeConversation(accountID: account.id, jid: "room@conference.example.com", type: .groupchat)
            try await store.upsertConversation(chat)
            try await store.upsertConversation(room)

            let fetchedRoom = try await store.fetchConversation(jid: "room@conference.example.com", type: .groupchat, accountID: account.id, importSourceJID: nil)
            #expect(fetchedRoom?.id == room.id)

            let fetchedChat = try await store.fetchConversation(jid: "alice@example.com", type: .chat, accountID: account.id, importSourceJID: nil)
            #expect(fetchedChat?.id == chat.id)
        }

        @Test
        func `Fetch conversation returns nil when not found`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let result = try await store.fetchConversation(jid: "nobody@example.com", type: .chat, accountID: account.id, importSourceJID: nil)
            #expect(result == nil)
        }

        @Test
        func `Mark conversation read resets unread count`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            var conversation = outer.makeConversation(accountID: account.id)
            conversation.unreadCount = 5
            try await store.upsertConversation(conversation)

            try await store.markConversationRead(conversation.id)

            let fetched = try await store.fetchConversations(for: account.id)
            #expect(fetched.first?.unreadCount == 0)
            #expect(fetched.first?.lastReadTimestamp != nil)
        }
    }

    // MARK: - Account Cleanup

    struct AccountCleanup {
        private let outer = SwiftDataPersistenceStoreTests()

        @Test
        func `Unlink conversations restores importSourceJID`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let conversation = outer.makeConversation(accountID: account.id)
            try await store.upsertConversation(conversation)

            try await store.unlinkConversations(for: account.id, restoreImportSourceJID: "user@example.com")

            let linked = try await store.fetchConversations(for: account.id)
            #expect(linked.isEmpty)

            let all = try await store.fetchAllConversations()
            #expect(all.count == 1)
            #expect(all.first?.accountID == nil)
            #expect(all.first?.importSourceJID == "user@example.com")
        }

        @Test
        func `Unlink then re-link round trip`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let conversation = outer.makeConversation(accountID: account.id)
            try await store.upsertConversation(conversation)

            try await store.unlinkConversations(for: account.id, restoreImportSourceJID: "user@example.com")

            // Verify conversations are discoverable by importSourceJID
            let imported = try await store.fetchConversations(importSourceJID: "user@example.com")
            #expect(imported.count == 1)
            #expect(imported.first?.id == conversation.id)
        }

        @Test
        func `Delete conversations removes only target account`() async throws {
            let store = try outer.makeStore()
            let account1 = outer.makeAccount(jid: "user1@example.com")
            let account2 = outer.makeAccount(jid: "user2@example.com")
            try await store.saveAccount(account1)
            try await store.saveAccount(account2)

            let conv1 = outer.makeConversation(accountID: account1.id, jid: "alice@example.com")
            let conv2 = outer.makeConversation(accountID: account2.id, jid: "bob@example.com")
            try await store.upsertConversation(conv1)
            try await store.upsertConversation(conv2)

            try await store.deleteConversations(for: account1.id)

            let remaining = try await store.fetchAllConversations()
            #expect(remaining.count == 1)
            #expect(remaining.first?.id == conv2.id)
        }

        @Test
        func `Delete contacts removes only target account`() async throws {
            let store = try outer.makeStore()
            let account1 = outer.makeAccount(jid: "user1@example.com")
            let account2 = outer.makeAccount(jid: "user2@example.com")
            try await store.saveAccount(account1)
            try await store.saveAccount(account2)

            let contact1 = outer.makeContact(accountID: account1.id, jid: "alice@example.com")
            let contact2 = outer.makeContact(accountID: account2.id, jid: "bob@example.com")
            try await store.upsertContact(contact1)
            try await store.upsertContact(contact2)

            try await store.deleteContacts(for: account1.id)

            let remaining1 = try await store.fetchContacts(for: account1.id)
            let remaining2 = try await store.fetchContacts(for: account2.id)
            #expect(remaining1.isEmpty)
            #expect(remaining2.count == 1)
            #expect(remaining2.first?.id == contact2.id)
        }
    }

    // MARK: - Edge Cases

    struct EdgeCases {
        private let outer = SwiftDataPersistenceStoreTests()

        @Test
        func `Fetch on empty store returns empty array`() async throws {
            let store = try outer.makeStore()
            let accounts = try await store.fetchAccounts()
            let contacts = try await store.fetchContacts(for: UUID())
            let conversations = try await store.fetchConversations(for: UUID())
            #expect(accounts.isEmpty)
            #expect(contacts.isEmpty)
            #expect(conversations.isEmpty)
        }

        @Test
        func `Delete nonexistent account is no-op`() async throws {
            let store = try outer.makeStore()
            try await store.deleteAccount(UUID())
            // No error thrown
        }
    }
}
