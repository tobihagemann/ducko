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
    func upsertConversation(_ conversation: Conversation) async throws

    // MARK: - Messages

    func fetchMessages(for conversationID: UUID, before: Date?, limit: Int) async throws -> [ChatMessage]
    func insertMessage(_ message: ChatMessage) async throws
    func markMessagesRead(in conversationID: UUID) async throws
    func messageExistsByServerID(_ serverID: String, conversationID: UUID) async throws -> Bool
    func messageExistsByStanzaID(_ stanzaID: String, conversationID: UUID) async throws -> Bool

    // MARK: - Message Updates

    func updateMessageDeliveryStatus(stanzaID: String, isDelivered: Bool) async throws
    func updateMessageBody(stanzaID: String, newBody: String, isEdited: Bool, editedAt: Date) async throws
    func updateMessageError(stanzaID: String, errorText: String) async throws

    // MARK: - Link Previews

    func fetchLinkPreview(for url: String) async throws -> LinkPreview?
    func upsertLinkPreview(_ preview: LinkPreview) async throws
}
