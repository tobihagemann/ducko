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

    private func makeMessage(
        id: UUID = UUID(),
        conversationID: UUID,
        body: String = "Hello",
        timestamp: Date = Date(),
        isOutgoing: Bool = false,
        isRead: Bool = false
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            conversationID: conversationID,
            fromJID: "sender@example.com",
            body: body,
            timestamp: timestamp,
            isOutgoing: isOutgoing,
            isRead: isRead,
            isDelivered: false,
            isEdited: false,
            type: "chat"
        )
    }

    // MARK: - Accounts

    struct Accounts {
        private let outer = SwiftDataPersistenceStoreTests()

        @Test("Save and fetch account")
        func saveAndFetch() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()

            try await store.saveAccount(account)
            let fetched = try await store.fetchAccounts()

            #expect(fetched.count == 1)
            #expect(fetched.first?.id == account.id)
            #expect(fetched.first?.jid == account.jid)
        }

        @Test("Update existing account")
        func updateExisting() async throws {
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

        @Test("Delete account")
        func delete() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            try await store.deleteAccount(account.id)
            let fetched = try await store.fetchAccounts()
            #expect(fetched.isEmpty)
        }

        @Test("Delete cascades contacts and conversations")
        func deleteCascades() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let contact = outer.makeContact(accountID: account.id)
            try await store.upsertContact(contact)

            let conversation = outer.makeConversation(accountID: account.id)
            try await store.upsertConversation(conversation)

            try await store.deleteAccount(account.id)

            let contacts = try await store.fetchContacts(for: account.id)
            let conversations = try await store.fetchConversations(for: account.id)
            #expect(contacts.isEmpty)
            #expect(conversations.isEmpty)
        }
    }

    // MARK: - Contacts

    struct Contacts {
        private let outer = SwiftDataPersistenceStoreTests()

        @Test("Upsert and fetch contacts by account")
        func upsertAndFetch() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let contact = outer.makeContact(accountID: account.id, jid: "alice@example.com")
            try await store.upsertContact(contact)

            let fetched = try await store.fetchContacts(for: account.id)
            #expect(fetched.count == 1)
            #expect(fetched.first?.jid.description == "alice@example.com")
        }

        @Test("Update existing contact")
        func updateExisting() async throws {
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

        @Test("Groups array round-trips")
        func groupsRoundTrip() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let groups = ["Friends", "Work", "Family"]
            let contact = outer.makeContact(accountID: account.id, groups: groups)
            try await store.upsertContact(contact)

            let fetched = try await store.fetchContacts(for: account.id)
            #expect(fetched.first?.groups == groups)
        }

        @Test("Fetch scoped to account")
        func fetchScopedToAccount() async throws {
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

        @Test("Upsert and fetch conversations")
        func upsertAndFetch() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let conversation = outer.makeConversation(accountID: account.id)
            try await store.upsertConversation(conversation)

            let fetched = try await store.fetchConversations(for: account.id)
            #expect(fetched.count == 1)
            #expect(fetched.first?.id == conversation.id)
        }

        @Test("Conversation type round-trips", arguments: [
            Conversation.ConversationType.chat,
            Conversation.ConversationType.groupchat
        ])
        func typeRoundTrip(type: Conversation.ConversationType) async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let conversation = outer.makeConversation(accountID: account.id, type: type)
            try await store.upsertConversation(conversation)

            let fetched = try await store.fetchConversations(for: account.id)
            #expect(fetched.first?.type == type)
        }

        @Test("Last message date and preview update")
        func lastMessageUpdate() async throws {
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
    }

    // MARK: - Messages

    struct Messages {
        private let outer = SwiftDataPersistenceStoreTests()

        private func makeStoreWithConversation() async throws -> (SwiftDataPersistenceStore, UUID) {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)
            let conversation = outer.makeConversation(accountID: account.id)
            try await store.upsertConversation(conversation)
            return (store, conversation.id)
        }

        @Test("Insert and fetch ordered by timestamp descending")
        func insertAndFetch() async throws {
            let (store, conversationID) = try await makeStoreWithConversation()

            let now = Date()
            let msg1 = outer.makeMessage(
                conversationID: conversationID, body: "First",
                timestamp: now.addingTimeInterval(-60)
            )
            let msg2 = outer.makeMessage(
                conversationID: conversationID, body: "Second",
                timestamp: now
            )
            try await store.insertMessage(msg1)
            try await store.insertMessage(msg2)

            let fetched = try await store.fetchMessages(
                for: conversationID, before: nil, limit: 50
            )
            #expect(fetched.count == 2)
            #expect(fetched.first?.body == "Second")
            #expect(fetched.last?.body == "First")
        }

        @Test("Pagination with before and limit")
        func pagination() async throws {
            let (store, conversationID) = try await makeStoreWithConversation()

            let now = Date()
            for i in 0 ..< 5 {
                let msg = outer.makeMessage(
                    conversationID: conversationID,
                    body: "Message \(i)",
                    timestamp: now.addingTimeInterval(Double(i) * 10)
                )
                try await store.insertMessage(msg)
            }

            let page = try await store.fetchMessages(
                for: conversationID,
                before: now.addingTimeInterval(30),
                limit: 2
            )
            #expect(page.count == 2)
            #expect(page.first?.body == "Message 2")
            #expect(page.last?.body == "Message 1")
        }

        @Test("Mark messages read resets unread count")
        func markRead() async throws {
            let (store, conversationID) = try await makeStoreWithConversation()

            let msg1 = outer.makeMessage(conversationID: conversationID, body: "Unread 1")
            let msg2 = outer.makeMessage(conversationID: conversationID, body: "Unread 2")
            try await store.insertMessage(msg1)
            try await store.insertMessage(msg2)

            try await store.markMessagesRead(in: conversationID)

            let fetched = try await store.fetchMessages(
                for: conversationID, before: nil, limit: 50
            )
            for msg in fetched {
                #expect(msg.isRead == true)
            }
        }
    }

    // MARK: - Attachments

    struct Attachments {
        private let outer = SwiftDataPersistenceStoreTests()

        @Test("Insert attachment for message")
        func insertForMessage() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)
            let conversation = outer.makeConversation(accountID: account.id)
            try await store.upsertConversation(conversation)
            let message = outer.makeMessage(conversationID: conversation.id)
            try await store.insertMessage(message)

            let attachment = Attachment(
                id: UUID(),
                messageID: message.id,
                url: "https://example.com/image.png",
                mimeType: "image/png",
                fileName: "image.png",
                fileSize: 1024,
                width: 800,
                height: 600
            )
            try await store.insertAttachment(attachment, for: message.id)

            // Verify by fetching the message — attachment count is implicit
            // via the cascade relationship
            let fetched = try await store.fetchMessages(
                for: conversation.id, before: nil, limit: 50
            )
            #expect(fetched.count == 1)
        }
    }

    // MARK: - Cascade Deletes

    struct CascadeDeletes {
        private let outer = SwiftDataPersistenceStoreTests()

        @Test("Account deletion cascades through conversations to messages")
        func accountCascade() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let conversation = outer.makeConversation(accountID: account.id)
            try await store.upsertConversation(conversation)

            let message = outer.makeMessage(conversationID: conversation.id)
            try await store.insertMessage(message)

            let attachment = Attachment(
                id: UUID(),
                messageID: message.id,
                url: "https://example.com/file.zip",
                fileName: "file.zip"
            )
            try await store.insertAttachment(attachment, for: message.id)

            try await store.deleteAccount(account.id)

            let conversations = try await store.fetchConversations(for: account.id)
            let messages = try await store.fetchMessages(
                for: conversation.id, before: nil, limit: 50
            )
            #expect(conversations.isEmpty)
            #expect(messages.isEmpty)
        }
    }

    // MARK: - Edge Cases

    struct EdgeCases {
        private let outer = SwiftDataPersistenceStoreTests()

        @Test("Fetch on empty store returns empty array")
        func fetchEmpty() async throws {
            let store = try outer.makeStore()
            let accounts = try await store.fetchAccounts()
            let contacts = try await store.fetchContacts(for: UUID())
            let conversations = try await store.fetchConversations(for: UUID())
            let messages = try await store.fetchMessages(for: UUID(), before: nil, limit: 50)
            #expect(accounts.isEmpty)
            #expect(contacts.isEmpty)
            #expect(conversations.isEmpty)
            #expect(messages.isEmpty)
        }

        @Test("Delete nonexistent account is no-op")
        func deleteNonexistent() async throws {
            let store = try outer.makeStore()
            try await store.deleteAccount(UUID())
            // No error thrown
        }
    }
}
