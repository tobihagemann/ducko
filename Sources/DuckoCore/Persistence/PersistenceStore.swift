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

    // MARK: - Messages

    func fetchMessages(for conversationID: UUID, before: Date?, limit: Int) async throws -> [ChatMessage]
    func insertMessage(_ message: ChatMessage) async throws
    func markMessagesRead(in conversationID: UUID) async throws
    func fetchMessageByStanzaID(_ stanzaID: String) async throws -> ChatMessage?
    func messageExistsByServerID(_ serverID: String, conversationID: UUID) async throws -> Bool
    func messageExistsByStanzaID(_ stanzaID: String, conversationID: UUID) async throws -> Bool

    // MARK: - Batch Operations (Import)

    func insertMessages(_ messages: [ChatMessage]) async throws
    func existingStanzaIDs(_ stanzaIDs: Set<String>, in conversationID: UUID) async throws -> Set<String>

    // MARK: - Cross-Conversation Queries (Transcripts)

    func fetchAllConversations() async throws -> [Conversation]
    func searchMessages(query: String, conversationID: UUID?, before: Date?, after: Date?, limit: Int) async throws -> [ChatMessage]
    // periphery:ignore - infrastructure for transcript viewer detail pane (not wired up yet)
    func messageCount(for conversationID: UUID) async throws -> Int
    // periphery:ignore - infrastructure for transcript viewer detail pane (not wired up yet)
    func messageDateRange(for conversationID: UUID) async throws -> (earliest: Date, latest: Date)?

    // MARK: - Message Updates

    func updateMessageDeliveryStatus(stanzaID: String, isDelivered: Bool) async throws
    func updateMessageBody(stanzaID: String, newBody: String, isEdited: Bool, editedAt: Date) async throws
    func updateMessageError(stanzaID: String, errorText: String) async throws
    func markMessageRetracted(stanzaID: String, retractedAt: Date) async throws
    func markMessageRetractedByServerID(_ serverID: String, retractedAt: Date) async throws

    // MARK: - Link Previews

    func fetchLinkPreview(for url: String) async throws -> LinkPreview?
    func upsertLinkPreview(_ preview: LinkPreview) async throws
}

// MARK: - Default Implementations

public extension PersistenceStore {
    func insertMessages(_ messages: [ChatMessage]) async throws {
        for message in messages {
            try await insertMessage(message)
        }
    }

    func existingStanzaIDs(_ stanzaIDs: Set<String>, in conversationID: UUID) async throws -> Set<String> {
        var existing = Set<String>()
        for stanzaID in stanzaIDs where try await messageExistsByStanzaID(stanzaID, conversationID: conversationID) {
            existing.insert(stanzaID)
        }
        return existing
    }

    func fetchAllConversations() async throws -> [Conversation] {
        let accounts = try await fetchAccounts()
        var all: [Conversation] = []
        for account in accounts {
            all += try await fetchConversations(for: account.id)
        }
        return all
    }

    func searchMessages(query: String, conversationID: UUID?, before: Date?, after: Date?, limit: Int) async throws -> [ChatMessage] {
        []
    }

    // periphery:ignore - infrastructure for transcript viewer detail pane (not wired up yet)
    func messageCount(for conversationID: UUID) async throws -> Int {
        let messages = try await fetchMessages(for: conversationID, before: nil, limit: Int.max)
        return messages.count
    }

    // periphery:ignore - infrastructure for transcript viewer detail pane (not wired up yet)
    func messageDateRange(for conversationID: UUID) async throws -> (earliest: Date, latest: Date)? {
        nil
    }
}
