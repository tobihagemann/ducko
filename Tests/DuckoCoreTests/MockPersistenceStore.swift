import Foundation
import DuckoCore

actor MockPersistenceStore: PersistenceStore {
    var accounts: [Account] = []
    var contacts: [Contact] = []
    var conversations: [Conversation] = []
    var messages: [ChatMessage] = []
    var attachments: [Attachment] = []

    // MARK: - Accounts

    func fetchAccounts() async throws -> [Account] {
        accounts
    }

    func saveAccount(_ account: Account) async throws {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
    }

    func deleteAccount(_ id: UUID) async throws {
        accounts.removeAll { $0.id == id }
    }

    // MARK: - Contacts

    func fetchContacts(for accountID: UUID) async throws -> [Contact] {
        contacts.filter { $0.accountID == accountID }
    }

    func upsertContact(_ contact: Contact) async throws {
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[index] = contact
        } else {
            contacts.append(contact)
        }
    }

    // MARK: - Conversations

    func fetchConversations(for accountID: UUID) async throws -> [Conversation] {
        conversations.filter { $0.accountID == accountID }
    }

    func upsertConversation(_ conversation: Conversation) async throws {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.append(conversation)
        }
    }

    // MARK: - Messages

    func fetchMessages(for conversationID: UUID, before: Date?, limit: Int) async throws -> [ChatMessage] {
        var filtered = messages.filter { $0.conversationID == conversationID }
        if let before {
            filtered = filtered.filter { $0.timestamp < before }
        }
        return Array(filtered.sorted(by: { $0.timestamp > $1.timestamp }).prefix(limit))
    }

    func insertMessage(_ message: ChatMessage) async throws {
        messages.append(message)
    }

    func markMessagesRead(in conversationID: UUID) async throws {
        for index in messages.indices where messages[index].conversationID == conversationID {
            messages[index].isRead = true
        }
    }

    // MARK: - Attachments

    func insertAttachment(_ attachment: Attachment, for messageID: UUID) async throws {
        attachments.append(attachment)
    }
}
