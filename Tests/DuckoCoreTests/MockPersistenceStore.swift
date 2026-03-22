import DuckoCore
import Foundation

actor MockPersistenceStore: PersistenceStore {
    var accounts: [Account] = []
    var contacts: [Contact] = []
    var conversations: [Conversation] = []
    var messages: [ChatMessage] = []
    var linkPreviews: [LinkPreview] = []

    // MARK: - Test Helpers

    func addConversation(_ conversation: Conversation) {
        conversations.append(conversation)
    }

    func addMessage(_ message: ChatMessage) {
        messages.append(message)
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

    func fetchMessageByStanzaID(_ stanzaID: String) async throws -> ChatMessage? {
        messages.first { $0.stanzaID == stanzaID }
    }

    func messageExistsByServerID(_ serverID: String, conversationID: UUID) async throws -> Bool {
        messages.contains { $0.serverID == serverID && $0.conversationID == conversationID }
    }

    func messageExistsByStanzaID(_ stanzaID: String, conversationID: UUID) async throws -> Bool {
        messages.contains { $0.stanzaID == stanzaID && $0.conversationID == conversationID }
    }

    func markMessagesRead(in conversationID: UUID) async throws {
        for index in messages.indices where messages[index].conversationID == conversationID {
            messages[index].isRead = true
        }
    }

    // MARK: - Batch Operations (Import)

    func insertMessages(_ messages: [ChatMessage]) async throws {
        self.messages.append(contentsOf: messages)
    }

    func existingStanzaIDs(_ stanzaIDs: Set<String>, in conversationID: UUID) async throws -> Set<String> {
        let existing = messages
            .filter { $0.conversationID == conversationID }
            .compactMap(\.stanzaID)
        return stanzaIDs.intersection(existing)
    }

    // MARK: - Cross-Conversation Queries (Transcripts)

    func fetchAllConversations() async throws -> [Conversation] {
        conversations
    }

    func searchMessages(query: String, conversationID: UUID?, before: Date?, after: Date?, limit: Int) async throws -> [ChatMessage] {
        var results = messages.filter { $0.body.localizedStandardContains(query) }
        if let conversationID {
            results = results.filter { $0.conversationID == conversationID }
        }
        if let before {
            results = results.filter { $0.timestamp < before }
        }
        if let after {
            results = results.filter { $0.timestamp > after }
        }
        return Array(results.sorted(by: { $0.timestamp > $1.timestamp }).prefix(limit))
    }

    func messageCount(for conversationID: UUID) async throws -> Int {
        messages.count(where: { $0.conversationID == conversationID })
    }

    func messageDateRange(for conversationID: UUID) async throws -> (earliest: Date, latest: Date)? {
        let convMessages = messages.filter { $0.conversationID == conversationID }
        guard let earliest = convMessages.min(by: { $0.timestamp < $1.timestamp })?.timestamp,
              let latest = convMessages.max(by: { $0.timestamp < $1.timestamp })?.timestamp else {
            return nil
        }
        return (earliest, latest)
    }

    // MARK: - Message Updates

    func updateMessageDeliveryStatus(stanzaID: String, isDelivered: Bool) async throws {
        for index in messages.indices where messages[index].stanzaID == stanzaID {
            messages[index].isDelivered = isDelivered
        }
    }

    func updateMessageBody(stanzaID: String, newBody: String, isEdited: Bool, editedAt: Date) async throws {
        for index in messages.indices where messages[index].stanzaID == stanzaID {
            messages[index].body = newBody
            messages[index].isEdited = isEdited
            messages[index].editedAt = editedAt
        }
    }

    func updateMessageError(stanzaID: String, errorText: String) async throws {
        for index in messages.indices where messages[index].stanzaID == stanzaID {
            messages[index].errorText = errorText
        }
    }

    func markMessageRetracted(stanzaID: String, retractedAt: Date) async throws {
        applyRetraction(matching: { $0.stanzaID == stanzaID }, retractedAt: retractedAt)
    }

    func markMessageRetractedByServerID(_ serverID: String, retractedAt: Date) async throws {
        applyRetraction(matching: { $0.serverID == serverID }, retractedAt: retractedAt)
    }

    private func applyRetraction(matching predicate: (ChatMessage) -> Bool, retractedAt: Date) {
        for index in messages.indices where predicate(messages[index]) {
            messages[index].isRetracted = true
            messages[index].retractedAt = retractedAt
            messages[index].body = ""
            messages[index].htmlBody = nil
        }
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
