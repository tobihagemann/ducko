import DuckoXMPP
import Foundation

@MainActor @Observable
public final class ChatService {
    public private(set) var openConversations: [Conversation] = []
    public private(set) var activeConversationID: UUID?
    public private(set) var messages: [ChatMessage] = []

    private let store: any PersistenceStore
    private let filterPipeline: MessageFilterPipeline
    private weak var accountService: AccountService?

    public init(store: any PersistenceStore, filterPipeline: MessageFilterPipeline) {
        self.store = store
        self.filterPipeline = filterPipeline
    }

    // MARK: - Wiring

    func setAccountService(_ service: AccountService) {
        accountService = service
    }

    // MARK: - Public API

    public func loadConversations(for accountID: UUID) async throws {
        openConversations = try await store.fetchConversations(for: accountID)
    }

    public func sendMessage(to jid: BareJID, body: String, accountID: UUID) async throws {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let chatModule = await client.module(ofType: ChatModule.self) else { return }

        let content = MessageContent(body: body)
        let filterContext = FilterContext(conversationJID: jid, accountJID: accountJID(for: accountID, fallback: jid))
        let filtered = await filterPipeline.process(content, direction: .outgoing, context: filterContext)

        let recipient = JID.bare(jid)
        try await chatModule.sendMessage(to: recipient, body: filtered.body)

        // Persist outgoing message
        let conversation = try await findOrCreateConversation(for: jid, accountID: accountID)

        let message = ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            fromJID: jid.description,
            body: filtered.body,
            htmlBody: filtered.htmlBody,
            timestamp: Date(),
            isOutgoing: true,
            isRead: true,
            isDelivered: false,
            isEdited: false,
            type: "chat"
        )
        try await persistMessage(message, in: conversation, accountID: accountID)
    }

    public func selectConversation(_ id: UUID?, accountID: UUID? = nil) async {
        activeConversationID = id
        guard let id else {
            messages = []
            return
        }
        messages = await loadMessages(for: id)
        try? await store.markMessagesRead(in: id)
        if let accountID {
            openConversations = await (try? store.fetchConversations(for: accountID)) ?? openConversations
        }
    }

    public func openConversation(for jid: BareJID, accountID: UUID) async throws -> Conversation {
        let conversation = try await findOrCreateConversation(for: jid, accountID: accountID)
        openConversations = try await store.fetchConversations(for: accountID)
        return conversation
    }

    public func openConversation(jidString: String, accountID: UUID) async throws -> Conversation {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        return try await openConversation(for: jid, accountID: accountID)
    }

    public func startConversation(jidString: String, accountID: UUID) async throws -> UUID {
        try await openConversation(jidString: jidString, accountID: accountID).id
    }

    public func sendMessage(toJIDString jidString: String, body: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        try await sendMessage(to: jid, body: body, accountID: accountID)
    }

    public enum ChatServiceError: Error, LocalizedError {
        case invalidJID(String)

        public var errorDescription: String? {
            switch self {
            case let .invalidJID(string): "Invalid JID: \(string)"
            }
        }
    }

    // MARK: - Event Handling

    func handleEvent(_ event: XMPPEvent, accountID: UUID) async {
        switch event {
        case let .messageReceived(xmppMessage):
            await handleMessageReceived(xmppMessage, accountID: accountID)
        default:
            break
        }
    }

    // MARK: - Private

    private func accountJID(for accountID: UUID, fallback: BareJID) -> BareJID {
        accountService?.accounts.first { $0.id == accountID }?.jid ?? fallback
    }

    private func handleMessageReceived(_ xmppMessage: XMPPMessage, accountID: UUID) async {
        guard xmppMessage.messageType == .chat,
              let body = xmppMessage.body,
              let fromJID = xmppMessage.from?.bareJID else { return }

        let stanzaID = xmppMessage.id
        if await isDuplicate(stanzaID: stanzaID, from: fromJID, accountID: accountID) {
            return
        }

        let conversation: Conversation
        do {
            conversation = try await findOrCreateConversation(for: fromJID, accountID: accountID)
        } catch {
            return
        }

        let content = MessageContent(body: body)
        let filterContext = FilterContext(conversationJID: fromJID, accountJID: accountJID(for: accountID, fallback: fromJID))
        let filtered = await filterPipeline.process(content, direction: .incoming, context: filterContext)

        let message = ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            stanzaID: stanzaID,
            fromJID: fromJID.description,
            body: filtered.body,
            htmlBody: filtered.htmlBody,
            timestamp: Date(),
            isOutgoing: false,
            isRead: false,
            isDelivered: false,
            isEdited: false,
            type: "chat"
        )
        try? await persistMessage(message, in: conversation, incrementUnread: true, accountID: accountID)
    }

    private func persistMessage(
        _ message: ChatMessage,
        in conversation: Conversation,
        incrementUnread: Bool = false,
        accountID: UUID
    ) async throws {
        try await store.insertMessage(message)

        var updated = conversation
        updated.lastMessageDate = message.timestamp
        updated.lastMessagePreview = String(message.body.prefix(100))
        if incrementUnread {
            updated.unreadCount += 1
        }
        try await store.upsertConversation(updated)

        openConversations = try await store.fetchConversations(for: accountID)

        if conversation.id == activeConversationID {
            messages = await loadMessages(for: conversation.id)
        }
    }

    private func isDuplicate(stanzaID: String?, from jid: BareJID, accountID: UUID) async -> Bool {
        guard let stanzaID else { return false }
        guard let conversation = openConversations.first(where: { $0.jid == jid && $0.accountID == accountID }) else {
            return false
        }
        let existing = try? await store.fetchMessages(for: conversation.id, before: nil, limit: 50)
        return existing?.contains { $0.stanzaID == stanzaID } ?? false
    }

    public func loadMessages(for conversationID: UUID) async -> [ChatMessage] {
        let fetched = try? await store.fetchMessages(for: conversationID, before: nil, limit: 50)
        return (fetched ?? []).reversed()
    }

    private func findOrCreateConversation(for jid: BareJID, accountID: UUID) async throws -> Conversation {
        let conversations = try await store.fetchConversations(for: accountID)
        if let existing = conversations.first(where: { $0.jid == jid }) {
            return existing
        }

        let conversation = Conversation(
            id: UUID(),
            accountID: accountID,
            jid: jid,
            type: .chat,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            createdAt: Date()
        )
        try await store.upsertConversation(conversation)
        return conversation
    }
}
