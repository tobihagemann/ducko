import DuckoXMPP
import Foundation

@MainActor @Observable
public final class ChatService {
    public private(set) var openConversations: [Conversation] = []
    public private(set) var activeConversationID: UUID?
    public private(set) var messages: [ChatMessage] = []
    public private(set) var typingStates: [BareJID: ChatState] = [:]
    public var onIncomingMessage: ((ChatMessage, Conversation) -> Void)?

    private let store: any PersistenceStore
    private let filterPipeline: MessageFilterPipeline
    private weak var accountService: AccountService?
    private var typingDebounce: [BareJID: Task<Void, Never>] = [:]

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
        let stanzaID = client.generateID()
        try await chatModule.sendMessage(to: recipient, body: filtered.body, id: stanzaID, requestReceipt: true)

        // Persist outgoing message
        let conversation = try await findOrCreateConversation(for: jid, accountID: accountID)

        let message = ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            stanzaID: stanzaID,
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

    // MARK: - Typing

    public func userIsTyping(in jid: BareJID, accountID: UUID) async {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let module = await client.module(ofType: ChatStatesModule.self) else { return }

        // Cancel existing debounce
        typingDebounce[jid]?.cancel()

        // Send composing
        try? await module.sendChatState(.composing, to: .bare(jid))

        // Schedule paused after 5 seconds
        typingDebounce[jid] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            try? await module.sendChatState(.paused, to: .bare(jid))
            self?.typingDebounce[jid] = nil
        }
    }

    public func userIsTyping(inJIDString jidString: String, accountID: UUID) async {
        guard let jid = BareJID.parse(jidString) else { return }
        await userIsTyping(in: jid, accountID: accountID)
    }

    public func isPartnerTyping(jidString: String) -> Bool {
        guard let jid = BareJID.parse(jidString) else { return false }
        return typingStates[jid] == .composing
    }

    // MARK: - Corrections

    public func sendCorrection(
        to jid: BareJID,
        originalStanzaID: String,
        newBody: String,
        accountID: UUID
    ) async throws {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let chatModule = await client.module(ofType: ChatModule.self) else { return }

        try await chatModule.sendCorrection(to: .bare(jid), body: newBody, replacingID: originalStanzaID)
        try await store.updateMessageBody(stanzaID: originalStanzaID, newBody: newBody, isEdited: true, editedAt: Date())
        await reloadActiveMessages()
    }

    public func sendCorrection(
        toJIDString jidString: String,
        originalStanzaID: String,
        newBody: String,
        accountID: UUID
    ) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        try await sendCorrection(to: jid, originalStanzaID: originalStanzaID, newBody: newBody, accountID: accountID)
    }

    // MARK: - Replies

    public func sendReply(
        to jid: BareJID,
        body: String,
        replyToStanzaID: String,
        accountID: UUID
    ) async throws {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let chatModule = await client.module(ofType: ChatModule.self) else { return }

        let content = MessageContent(body: body)
        let filterContext = FilterContext(conversationJID: jid, accountJID: accountJID(for: accountID, fallback: jid))
        let filtered = await filterPipeline.process(content, direction: .outgoing, context: filterContext)

        let stanzaID = client.generateID()
        try await chatModule.sendReply(
            to: .bare(jid),
            body: filtered.body,
            replyToID: replyToStanzaID,
            replyToJID: .bare(jid),
            id: stanzaID
        )

        let conversation = try await findOrCreateConversation(for: jid, accountID: accountID)
        let message = ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            stanzaID: stanzaID,
            fromJID: jid.description,
            body: filtered.body,
            htmlBody: filtered.htmlBody,
            timestamp: Date(),
            isOutgoing: true,
            isRead: true,
            isDelivered: false,
            isEdited: false,
            type: "chat",
            replyToID: replyToStanzaID
        )
        try await persistMessage(message, in: conversation, accountID: accountID)
    }

    public func sendReply(
        toJIDString jidString: String,
        body: String,
        replyToStanzaID: String,
        accountID: UUID
    ) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        try await sendReply(to: jid, body: body, replyToStanzaID: replyToStanzaID, accountID: accountID)
    }

    // MARK: - Markers

    public func sendDisplayedMarker(
        to jid: BareJID,
        messageStanzaID: String,
        accountID: UUID
    ) async throws {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let module = await client.module(ofType: ReceiptsModule.self) else { return }
        try await module.sendDisplayedMarker(to: .bare(jid), messageID: messageStanzaID)
    }

    public func sendDisplayedMarker(
        toJIDString jidString: String,
        messageStanzaID: String,
        accountID: UUID
    ) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        try await sendDisplayedMarker(to: jid, messageStanzaID: messageStanzaID, accountID: accountID)
    }

    // MARK: - Pin/Mute

    public func togglePin(conversationID: UUID, accountID: UUID) async throws {
        try await mutateConversation(conversationID, accountID: accountID) { $0.isPinned.toggle() }
    }

    public func toggleMute(conversationID: UUID, accountID: UUID) async throws {
        try await mutateConversation(conversationID, accountID: accountID) { $0.isMuted.toggle() }
    }

    private func mutateConversation(
        _ conversationID: UUID,
        accountID: UUID,
        _ mutate: (inout Conversation) -> Void
    ) async throws {
        guard var conversation = openConversations.first(where: { $0.id == conversationID }) else { return }
        mutate(&conversation)
        try await store.upsertConversation(conversation)
        openConversations = try await store.fetchConversations(for: accountID)
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
        case let .deliveryReceiptReceived(messageID, _):
            await handleDeliveryReceipt(messageID: messageID)
        case let .chatMarkerReceived(messageID, markerType, _):
            await handleChatMarker(messageID: messageID, type: markerType)
        case let .chatStateChanged(from, chatState):
            handleChatStateChanged(from: from, state: chatState)
        case let .messageCorrected(originalID, newBody, _):
            await handleMessageCorrected(originalID: originalID, newBody: newBody)
        case let .messageError(messageID, _, errorText):
            await handleMessageError(messageID: messageID, errorText: errorText)
        default:
            break
        }
    }

    // MARK: - Private: Event Handlers

    private func handleDeliveryReceipt(messageID: String) async {
        try? await store.updateMessageDeliveryStatus(stanzaID: messageID, isDelivered: true)
        await reloadActiveMessages()
    }

    private func handleChatMarker(messageID: String, type: ChatMarkerType) async {
        guard type == .displayed else { return }
        try? await store.updateMessageDeliveryStatus(stanzaID: messageID, isDelivered: true)
        await reloadActiveMessages()
    }

    private func handleChatStateChanged(from: BareJID, state: ChatState) {
        typingStates[from] = state
    }

    private func handleMessageCorrected(originalID: String, newBody: String) async {
        try? await store.updateMessageBody(stanzaID: originalID, newBody: newBody, isEdited: true, editedAt: Date())
        await reloadActiveMessages()
    }

    private func handleMessageError(messageID: String?, errorText: String) async {
        guard let messageID else { return }
        try? await store.updateMessageError(stanzaID: messageID, errorText: errorText)
        await reloadActiveMessages()
    }

    // MARK: - Private

    private func reloadActiveMessages() async {
        if let activeConversationID {
            messages = await loadMessages(for: activeConversationID)
        }
    }

    private func accountJID(for accountID: UUID, fallback: BareJID) -> BareJID {
        accountService?.accounts.first { $0.id == accountID }?.jid ?? fallback
    }

    private func handleMessageReceived(_ xmppMessage: XMPPMessage, accountID: UUID) async {
        // Skip corrections — handled by .messageCorrected event
        if xmppMessage.element.child(named: "replace", namespace: XMPPNamespaces.messageCorrect) != nil {
            return
        }

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

        // Parse XEP-0461 reply
        let replyToID = xmppMessage.element.child(named: "reply", namespace: XMPPNamespaces.messageReply)?.attribute("id")

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
            type: "chat",
            replyToID: replyToID
        )
        try? await persistMessage(message, in: conversation, incrementUnread: true, accountID: accountID)

        onIncomingMessage?(message, conversation)
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
        await (try? fetchMessageHistory(for: conversationID, before: nil, limit: 50)) ?? []
    }

    public func fetchMessageHistory(
        for conversationID: UUID,
        before: Date?,
        limit: Int
    ) async throws -> [ChatMessage] {
        let messages = try await store.fetchMessages(for: conversationID, before: before, limit: limit)
        return messages.reversed()
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
