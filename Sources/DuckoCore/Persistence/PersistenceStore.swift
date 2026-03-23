import Foundation

public protocol PersistenceStore: Sendable {
    // MARK: - Accounts

    func fetchAccounts() async throws -> [Account]
    func saveAccount(_ account: Account) async throws
    func deleteAccount(_ id: UUID) async throws

    // MARK: - Contacts

    func fetchContacts(for accountID: UUID) async throws -> [Contact]
    func upsertContact(_ contact: Contact) async throws
    func deleteContact(_ id: UUID) async throws

    // MARK: - Conversations

    func fetchConversations(for accountID: UUID) async throws -> [Conversation]
    func fetchConversation(jid: String, type: Conversation.ConversationType, accountID: UUID) async throws -> Conversation?
    func upsertConversation(_ conversation: Conversation) async throws
    func fetchAllConversations() async throws -> [Conversation]
    func markConversationRead(_ conversationID: UUID) async throws

    // MARK: - Link Previews

    func fetchLinkPreview(for url: String) async throws -> LinkPreview?
    func upsertLinkPreview(_ preview: LinkPreview) async throws
}

// MARK: - Default Implementations

public extension PersistenceStore {
    func fetchAllConversations() async throws -> [Conversation] {
        let accounts = try await fetchAccounts()
        var all: [Conversation] = []
        for account in accounts {
            all += try await fetchConversations(for: account.id)
        }
        return all
    }
}
