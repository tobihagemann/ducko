import DuckoCore
import Foundation

public actor MockPersistenceStore: PersistenceStore {
    public var accounts: [Account] = []
    public var contacts: [Contact] = []
    public var conversations: [Conversation] = []
    public var linkPreviews: [LinkPreview] = []
    /// Test seam: when set, `fetchConversations(for:)` throws this instead of returning, so the
    /// account-aware cache's failed-fetch-leaves-the-slot-intact path is exercisable.
    public var fetchConversationsError: Error?

    public init() {}

    public func setFetchConversationsError(_ error: Error?) {
        fetchConversationsError = error
    }

    public func addAccount(_ account: Account) {
        accounts.append(account)
    }

    public func addConversation(_ conversation: Conversation) {
        conversations.append(conversation)
    }

    // MARK: - Accounts

    public func fetchAccounts() async throws -> [Account] {
        accounts
    }

    public func saveAccount(_ account: Account) async throws {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
    }

    public func deleteAccount(_ id: UUID) async throws {
        accounts.removeAll { $0.id == id }
    }

    // MARK: - Contacts

    public func fetchContacts(for accountID: UUID) async throws -> [Contact] {
        contacts.filter { $0.accountID == accountID }
    }

    public func upsertContact(_ contact: Contact) async throws {
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[index] = contact
        } else {
            contacts.append(contact)
        }
    }

    public func deleteContact(_ id: UUID) async throws {
        contacts.removeAll { $0.id == id }
    }

    // MARK: - Conversations

    public func fetchConversations(for accountID: UUID) async throws -> [Conversation] {
        if let fetchConversationsError { throw fetchConversationsError }
        return conversations.filter { $0.accountID == accountID }
    }

    public func fetchConversations(importSourceJID: String) async throws -> [Conversation] {
        conversations.filter { $0.importSourceJID == importSourceJID }
    }

    public func fetchConversation(jid: String, type: Conversation.ConversationType, accountID: UUID?, importSourceJID: String?) async throws -> Conversation? {
        conversations.first { $0.jid.description == jid && $0.type == type && $0.accountID == accountID && $0.importSourceJID == importSourceJID }
    }

    public func upsertConversation(_ conversation: Conversation) async throws {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.append(conversation)
        }
    }

    public func fetchAllConversations() async throws -> [Conversation] {
        conversations
    }

    public func markConversationRead(_ conversationID: UUID) async throws {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].unreadCount = 0
        conversations[index].lastReadTimestamp = Date()
    }

    // MARK: - Account Cleanup

    public func unlinkConversations(for accountID: UUID, restoreImportSourceJID: String) async throws {
        for index in conversations.indices where conversations[index].accountID == accountID {
            conversations[index].accountID = nil
            conversations[index].importSourceJID = restoreImportSourceJID
        }
    }

    public func deleteConversations(for accountID: UUID) async throws {
        conversations.removeAll { $0.accountID == accountID }
    }

    public func deleteContacts(for accountID: UUID) async throws {
        contacts.removeAll { $0.accountID == accountID }
    }

    // MARK: - Link Previews

    public func fetchLinkPreview(for url: String) async throws -> LinkPreview? {
        linkPreviews.first { $0.url == url }
    }

    public func upsertLinkPreview(_ preview: LinkPreview) async throws {
        if let index = linkPreviews.firstIndex(where: { $0.url == preview.url }) {
            linkPreviews[index] = preview
        } else {
            linkPreviews.append(preview)
        }
    }
}
