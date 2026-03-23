import DuckoCore
import Foundation

actor MockPersistenceStore: PersistenceStore {
    var accounts: [Account] = []
    var contacts: [Contact] = []
    var conversations: [Conversation] = []
    var linkPreviews: [LinkPreview] = []

    // MARK: - Test Helpers

    func addConversation(_ conversation: Conversation) {
        conversations.append(conversation)
    }

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

    func deleteContact(_ id: UUID) async throws {
        contacts.removeAll { $0.id == id }
    }

    // MARK: - Conversations

    func fetchConversations(for accountID: UUID) async throws -> [Conversation] {
        conversations.filter { $0.accountID == accountID }
    }

    func fetchConversation(jid: String, type: Conversation.ConversationType, accountID: UUID) async throws -> Conversation? {
        conversations.first { $0.jid.description == jid && $0.type == type && $0.accountID == accountID }
    }

    func upsertConversation(_ conversation: Conversation) async throws {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.append(conversation)
        }
    }

    func markConversationRead(_ conversationID: UUID) async throws {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].unreadCount = 0
        conversations[index].lastReadTimestamp = Date()
    }

    // MARK: - Link Previews

    func fetchLinkPreview(for url: String) async throws -> LinkPreview? {
        linkPreviews.first { $0.url == url }
    }

    func upsertLinkPreview(_ preview: LinkPreview) async throws {
        if let index = linkPreviews.firstIndex(where: { $0.url == preview.url }) {
            linkPreviews[index] = preview
        } else {
            linkPreviews.append(preview)
        }
    }
}
