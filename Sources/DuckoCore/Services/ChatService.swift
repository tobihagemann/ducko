import DuckoXMPP
import Foundation
import os

private let log = Logger(subsystem: "com.ducko.core", category: "chat")

/// XEP-0424 fallback body for clients that don't support message retraction.
private let retractionFallbackBody = "This person attempted to retract a previous message, but it's unsupported by your client."

@MainActor @Observable
public final class ChatService {
    public private(set) var openConversations: [Conversation] = []
    public private(set) var activeConversationID: UUID?
    public private(set) var messages: [ChatMessage] = []
    public private(set) var typingStates: [BareJID: ChatState] = [:]
    public private(set) var roomParticipants: [String: [RoomParticipant]] = [:]
    public private(set) var pendingInvites: [PendingRoomInvite] = []
    public private(set) var newlyCreatedRoomJIDs: Set<String> = []
    public private(set) var roomFlags: [String: Set<RoomFlag>] = [:]
    public var onIncomingMessage: ((ChatMessage, Conversation) -> Void)?
    public var onHeadlineMessage: (@Sendable (XMPPMessage) -> Void)?

    private let store: any PersistenceStore
    private let filterPipeline: MessageFilterPipeline
    private weak var accountService: AccountService?
    private weak var omemoService: OMEMOService?
    private var typingDebounce: [BareJID: Task<Void, Never>] = [:]

    public init(store: any PersistenceStore, filterPipeline: MessageFilterPipeline) {
        self.store = store
        self.filterPipeline = filterPipeline
    }

    // MARK: - Wiring

    func setAccountService(_ service: AccountService) {
        accountService = service
    }

    func setOMEMOService(_ service: OMEMOService) {
        omemoService = service
    }

    // MARK: - Public API

    public func loadConversations(for accountID: UUID) async throws {
        openConversations = try await store.fetchConversations(for: accountID)
    }

    public func sendMessage(to jid: BareJID, body: String, accountID: UUID, additionalElements: [DuckoXMPP.XMLElement] = []) async throws {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let chatModule = await client.module(ofType: ChatModule.self) else { return }

        let content = MessageContent(body: body)
        let filterContext = FilterContext(accountJID: accountJID(for: accountID, fallback: jid))
        let filtered = await filterPipeline.process(content, direction: .outgoing, context: filterContext)

        let conversation = try await findOrCreateConversation(for: jid, accountID: accountID)
        let recipient = JID.bare(jid)
        let stanzaID = client.generateID()
        let chatStatesEnabled = ChatPreferences.shared.enableChatStates

        // Encrypt if conversation has encryption enabled and peer has trusted devices
        let encryptionEnabled = conversation.encryptionEnabled
        var isEncrypted = false
        if let omemoService, let trustedDeviceIDs = await omemoService.shouldEncrypt(jid: jid, accountID: accountID, conversationEncryptionEnabled: encryptionEnabled) {
            let elements = try await omemoService.encryptMessage(body: filtered.body, to: jid, trustedDeviceIDs: trustedDeviceIDs, accountID: accountID)
            let storeHint = DuckoXMPP.XMLElement(name: "store", namespace: XMPPNamespaces.processingHints)
            try await chatModule.sendMessage(
                to: recipient, body: elements.fallbackBody, id: stanzaID,
                requestReceipt: true, markable: true, includeChatState: chatStatesEnabled,
                additionalElements: [elements.encrypted, elements.encryption, storeHint]
            )
            isEncrypted = true
        } else {
            try await chatModule.sendMessage(to: recipient, body: filtered.body, id: stanzaID, requestReceipt: true, markable: true, includeChatState: chatStatesEnabled, additionalElements: additionalElements)
        }

        // Persist with the original body (not the OMEMO fallback)
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
            isEncrypted: isEncrypted
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
            await sendDisplayedMarkerForLatest(conversationID: id, accountID: accountID)
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

    public func setEncryptionEnabled(_ enabled: Bool, for conversationID: UUID, accountID: UUID) async throws {
        guard var conversation = openConversations.first(where: { $0.id == conversationID }) else { return }
        conversation.encryptionEnabled = enabled
        try await store.upsertConversation(conversation)
        openConversations = try await store.fetchConversations(for: accountID)
    }

    /// Persists an encrypted message received via OMEMO. Called by OMEMOService.
    func persistEncryptedMessage(_ message: ChatMessage, in conversation: Conversation, accountID: UUID) async {
        await persistAndNotify(message, in: conversation, accountID: accountID)
    }

    public func sendMessage(toJIDString jidString: String, body: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        try await sendMessage(to: jid, body: body, accountID: accountID)
    }

    // MARK: - Typing

    public func userIsTyping(in jid: BareJID, accountID: UUID) async {
        guard ChatPreferences.shared.enableChatStates else { return }
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
        guard let original = try? await store.fetchMessageByStanzaID(originalStanzaID),
              original.isOutgoing else {
            throw ChatServiceError.notOutgoingMessage
        }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let chatModule = await client.module(ofType: ChatModule.self) else { return }

        let conversation = try await findOrCreateConversation(for: jid, accountID: accountID)
        let chatStatesEnabled = ChatPreferences.shared.enableChatStates

        if let omemoService, let trustedDeviceIDs = await omemoService.shouldEncrypt(
            jid: jid, accountID: accountID, conversationEncryptionEnabled: conversation.encryptionEnabled
        ) {
            let elements = try await omemoService.encryptMessage(body: newBody, to: jid, trustedDeviceIDs: trustedDeviceIDs, accountID: accountID)
            let replaceElement = DuckoXMPP.XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": originalStanzaID])
            let storeHint = DuckoXMPP.XMLElement(name: "store", namespace: XMPPNamespaces.processingHints)
            try await chatModule.sendMessage(
                to: .bare(jid), body: elements.fallbackBody, id: client.generateID(),
                includeChatState: chatStatesEnabled,
                additionalElements: [elements.encrypted, elements.encryption, storeHint, replaceElement]
            )
        } else {
            try await chatModule.sendCorrection(to: .bare(jid), body: newBody, replacingID: originalStanzaID, includeChatState: chatStatesEnabled)
        }
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

    // MARK: - Group Corrections

    public func sendGroupCorrection(originalStanzaID: String, newBody: String, in room: BareJID, accountID: UUID) async throws {
        guard let original = try? await store.fetchMessageByStanzaID(originalStanzaID),
              original.isOutgoing else {
            throw ChatServiceError.notOutgoingMessage
        }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }

        let conversation = try await findOrCreateGroupConversation(for: room, nickname: nil, accountID: accountID)
        let replaceElement = DuckoXMPP.XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": originalStanzaID])
        _ = try await encryptAndSendGroupMessage(
            room: room, body: newBody, stanzaID: client.generateID(),
            conversation: conversation, mucModule: mucModule,
            additionalElements: [replaceElement]
        )
        try await store.updateMessageBody(stanzaID: originalStanzaID, newBody: newBody, isEdited: true, editedAt: Date())
        await reloadActiveMessages()
    }

    public func sendGroupCorrection(originalStanzaID: String, newBody: String, inRoomJIDString roomJIDString: String, accountID: UUID) async throws {
        guard let room = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        try await sendGroupCorrection(originalStanzaID: originalStanzaID, newBody: newBody, in: room, accountID: accountID)
    }

    // MARK: - Retractions

    public func retractMessage(stanzaID: String, to jid: BareJID, accountID: UUID) async throws {
        guard let original = try? await store.fetchMessageByStanzaID(stanzaID),
              original.isOutgoing else {
            throw ChatServiceError.notOutgoingMessage
        }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let chatModule = await client.module(ofType: ChatModule.self) else { return }

        let conversation = try await findOrCreateConversation(for: jid, accountID: accountID)

        if let omemoService, let trustedDeviceIDs = await omemoService.shouldEncrypt(
            jid: jid, accountID: accountID, conversationEncryptionEnabled: conversation.encryptionEnabled
        ) {
            let elements = try await omemoService.encryptMessage(body: retractionFallbackBody, to: jid, trustedDeviceIDs: trustedDeviceIDs, accountID: accountID)
            let retractElement = DuckoXMPP.XMLElement(name: "retract", namespace: XMPPNamespaces.messageRetract, attributes: ["id": stanzaID])
            let fallbackElement = DuckoXMPP.XMLElement(name: "fallback", namespace: XMPPNamespaces.fallbackIndication, attributes: ["for": XMPPNamespaces.messageRetract])
            let storeHint = DuckoXMPP.XMLElement(name: "store", namespace: XMPPNamespaces.processingHints)
            try await chatModule.sendMessage(
                to: .bare(jid), body: elements.fallbackBody, id: client.generateID(),
                includeChatState: false,
                additionalElements: [elements.encrypted, elements.encryption, storeHint, retractElement, fallbackElement]
            )
        } else {
            try await chatModule.sendRetraction(to: .bare(jid), originalID: stanzaID)
        }
        try await store.markMessageRetracted(stanzaID: stanzaID, retractedAt: Date())
        await reloadActiveMessages()
    }

    public func retractMessage(stanzaID: String, toJIDString jidString: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        try await retractMessage(stanzaID: stanzaID, to: jid, accountID: accountID)
    }

    public func retractGroupMessage(stanzaID: String, inRoomJIDString roomJIDString: String, accountID: UUID) async throws {
        guard let room = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        try await retractGroupMessage(stanzaID: stanzaID, in: room, accountID: accountID)
    }

    public func retractGroupMessage(stanzaID: String, in room: BareJID, accountID: UUID) async throws {
        guard let original = try? await store.fetchMessageByStanzaID(stanzaID),
              original.isOutgoing else {
            throw ChatServiceError.notOutgoingMessage
        }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }

        let conversation = try await findOrCreateGroupConversation(for: room, nickname: nil, accountID: accountID)
        let retractElement = DuckoXMPP.XMLElement(name: "retract", namespace: XMPPNamespaces.messageRetract, attributes: ["id": stanzaID])
        let fallbackElement = DuckoXMPP.XMLElement(name: "fallback", namespace: XMPPNamespaces.fallbackIndication, attributes: ["for": XMPPNamespaces.messageRetract])
        _ = try await encryptAndSendGroupMessage(
            room: room, body: retractionFallbackBody, stanzaID: client.generateID(),
            conversation: conversation, mucModule: mucModule,
            additionalElements: [retractElement, fallbackElement]
        )
        try await store.markMessageRetracted(stanzaID: stanzaID, retractedAt: Date())
        await reloadActiveMessages()
    }

    public func moderateMessage(serverID: String, inRoomJIDString roomJIDString: String, reason: String?, accountID: UUID) async throws {
        guard let room = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        try await moderateMessage(serverID: serverID, in: room, reason: reason, accountID: accountID)
    }

    public func moderateMessage(serverID: String, in room: BareJID, reason: String?, accountID: UUID) async throws {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }

        try await mucModule.moderateMessage(room: room, stanzaID: serverID, reason: reason)
        try await store.markMessageRetractedByServerID(serverID, retractedAt: Date())
        await reloadActiveMessages()
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
        let filterContext = FilterContext(accountJID: accountJID(for: accountID, fallback: jid))
        let filtered = await filterPipeline.process(content, direction: .outgoing, context: filterContext)

        let stanzaID = client.generateID()
        let chatStatesEnabled = ChatPreferences.shared.enableChatStates
        try await chatModule.sendReply(
            to: .bare(jid),
            body: filtered.body,
            replyToID: replyToStanzaID,
            replyToJID: .bare(jid),
            id: stanzaID,
            includeChatState: chatStatesEnabled
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
        accountID: UUID,
        messageType: DuckoXMPP.XMPPMessage.MessageType = .chat
    ) async throws {
        guard ChatPreferences.shared.enableDisplayedMarkers else { return }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let module = await client.module(ofType: ReceiptsModule.self) else { return }
        try await module.sendDisplayedMarker(to: .bare(jid), messageID: messageStanzaID, messageType: messageType)
    }

    // MARK: - Private: Displayed Markers

    private func sendDisplayedMarkerForLatest(conversationID: UUID, accountID: UUID) async {
        guard let conversation = openConversations.first(where: { $0.id == conversationID }) else { return }

        switch conversation.type {
        case .chat:
            guard let message = messages.last(where: { !$0.isOutgoing && $0.stanzaID != nil }) else { return }
            await sendDisplayedMarkerIfNeeded(for: message, in: conversation, accountID: accountID)
        case .groupchat:
            guard let message = messages.last(where: { !$0.isOutgoing && $0.serverID != nil }) else { return }
            await sendDisplayedMarkerIfNeeded(for: message, in: conversation, accountID: accountID)
        }
    }

    private func sendDisplayedMarkerIfNeeded(for message: ChatMessage, in conversation: Conversation, accountID: UUID) async {
        switch conversation.type {
        case .chat:
            if let stanzaID = message.stanzaID {
                try? await sendDisplayedMarker(to: conversation.jid, messageStanzaID: stanzaID, accountID: accountID)
            }
        case .groupchat:
            guard let serverID = message.serverID,
                  let client = accountService?.client(for: accountID),
                  let mucModule = await client.module(ofType: MUCModule.self),
                  mucModule.nickname(in: conversation.jid) != nil else { return }
            try? await sendDisplayedMarker(to: conversation.jid, messageStanzaID: serverID, accountID: accountID, messageType: .groupchat)
        }
    }

    // MARK: - MUC

    public func joinRoom(jid: BareJID, nickname: String, password: String? = nil, accountID: UUID) async throws {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }

        try await mucModule.joinRoom(jid, nickname: nickname, password: password)
        _ = try await findOrCreateGroupConversation(for: jid, nickname: nickname, accountID: accountID)
    }

    public func leaveRoom(jid: BareJID, accountID: UUID) async throws {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        try await mucModule.leaveRoom(jid)
    }

    public func sendGroupMessage(to room: BareJID, body: String, accountID: UUID, additionalElements: [DuckoXMPP.XMLElement] = []) async throws {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }

        let conversation = try await findOrCreateGroupConversation(for: room, nickname: nil, accountID: accountID)
        let stanzaID = client.generateID()
        let isEncrypted = try await encryptAndSendGroupMessage(
            room: room, body: body, stanzaID: stanzaID,
            conversation: conversation, mucModule: mucModule,
            additionalElements: additionalElements
        )

        let message = ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            stanzaID: stanzaID,
            fromJID: room.description,
            body: body,
            timestamp: Date(),
            isOutgoing: true,
            isRead: true,
            isDelivered: false,
            isEdited: false,
            type: "groupchat",
            isEncrypted: isEncrypted
        )
        try await persistMessage(message, in: conversation, accountID: accountID)
    }

    public func joinRoom(jidString: String, nickname: String, password: String? = nil, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        try await joinRoom(jid: jid, nickname: nickname, password: password, accountID: accountID)
    }

    public func leaveRoom(jidString: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        try await leaveRoom(jid: jid, accountID: accountID)
    }

    public func sendGroupMessage(toJIDString jidString: String, body: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        try await sendGroupMessage(to: jid, body: body, accountID: accountID)
    }

    public func sendMUCPrivateMessage(roomJIDString: String, nickname: String, body: String, accountID: UUID) async throws {
        guard let roomJID = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }

        let content = MessageContent(body: body)
        let filterContext = FilterContext(accountJID: accountJID(for: accountID, fallback: roomJID))
        let filtered = await filterPipeline.process(content, direction: .outgoing, context: filterContext)

        let conversation = try await findOrCreateMUCPMConversation(for: roomJID, nickname: nickname, accountID: accountID)
        let stanzaID = client.generateID()
        try await mucModule.sendPrivateMessage(to: roomJID, nickname: nickname, body: filtered.body, id: stanzaID)

        let message = ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            stanzaID: stanzaID,
            fromJID: nickname,
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

    public func openMUCPMConversation(roomJIDString: String, nickname: String, accountID: UUID) async throws -> Conversation {
        guard let roomJID = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        let conversation = try await findOrCreateMUCPMConversation(for: roomJID, nickname: nickname, accountID: accountID)
        openConversations = try await store.fetchConversations(for: accountID)
        return conversation
    }

    private func roomMemberJIDs(roomJIDString: String, accountID: UUID) async throws -> [BareJID] {
        guard let client = accountService?.client(for: accountID) else { return [] }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return [] }
        guard let roomJID = BareJID.parse(roomJIDString) else { return [] }

        let affiliations: [RoomAffiliation] = [.owner, .admin, .member]
        return await withTaskGroup(of: [BareJID].self) { group in
            for affiliation in affiliations {
                let xmppAffiliation = MUCAffiliation(rawValue: affiliation.rawValue) ?? .none
                group.addTask {
                    let items = await (try? mucModule.getAffiliationList(xmppAffiliation, in: roomJID)) ?? []
                    return items.map(\.jid)
                }
            }
            var result = Set<BareJID>()
            for await jids in group {
                result.formUnion(jids)
            }
            return Array(result)
        }
    }

    // MARK: - MUC Bridge

    public func participantGroups(forRoomJIDString jidString: String) -> [RoomParticipantGroup] {
        let participants = roomParticipants[jidString] ?? []
        let grouped = Dictionary(grouping: participants, by: \.affiliation)
        return grouped
            .map { RoomParticipantGroup(affiliation: $0.key, participants: $0.value.sorted { $0.nickname.localizedStandardCompare($1.nickname) == .orderedAscending }) }
            .sorted { $0.affiliation.sortPriority < $1.affiliation.sortPriority }
    }

    public func participantCount(forRoomJIDString jidString: String) -> Int {
        roomParticipants[jidString]?.count ?? 0
    }

    public func discoverMUCService(accountID: UUID) async -> String? {
        guard let client = accountService?.client(for: accountID) else { return nil }
        guard let disco = await client.module(ofType: ServiceDiscoveryModule.self) else { return nil }

        let account = accountService?.accounts.first { $0.id == accountID }
        guard let domain = account?.jid.domainPart,
              let domainJID = BareJID.parse(domain) else { return nil }
        guard let items = try? await disco.queryItems(for: .bare(domainJID)) else { return nil }

        for item in items {
            guard let info = try? await disco.queryInfo(for: item.jid) else { continue }
            if info.identities.contains(where: { $0.category == "conference" && $0.type == "text" }) {
                return item.jid.description
            }
        }
        return nil
    }

    public func discoverRooms(on service: String, accountID: UUID) async throws -> [DiscoveredRoom] {
        guard let client = accountService?.client(for: accountID) else { return [] }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return [] }

        let rooms = try await mucModule.discoverRooms(on: service)
        return rooms.map { DiscoveredRoom(jidString: $0.jid.description, name: $0.name) }
    }

    /// Searches for public channels via XEP-0433 Extended Channel Search.
    public func searchChannels(
        keyword: String,
        accountID: UUID,
        after: String? = nil
    ) async throws -> ChannelSearchResult {
        guard let client = accountService?.client(for: accountID) else { return ChannelSearchResult(channels: [], hasMore: false, lastCursor: nil) }
        guard let searchModule = await client.module(ofType: ChannelSearchModule.self) else { return ChannelSearchResult(channels: [], hasMore: false, lastCursor: nil) }

        let query = ChannelSearchModule.SearchQuery(keyword: keyword, after: after)
        let result = try await searchModule.search(query)

        let channels = result.items.map {
            SearchedChannel(
                jidString: $0.address.description,
                name: $0.name,
                userCount: $0.userCount,
                isOpen: $0.isOpen,
                description: $0.description
            )
        }

        let hasMore = !result.items.isEmpty && result.lastID != nil
        return ChannelSearchResult(channels: channels, hasMore: hasMore, lastCursor: result.lastID)
    }

    public func setRoomSubject(jidString: String, subject: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        try await mucModule.setSubject(in: jid, subject: subject)
    }

    public func inviteUser(jidString: String, toRoomJIDString roomJIDString: String, reason: String?, password: String? = nil, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        guard let roomJID = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        try await mucModule.inviteUser(jid, to: roomJID, reason: reason, password: password)
    }

    public func kickOccupant(nickname: String, fromRoomJIDString roomJIDString: String, reason: String?, accountID: UUID) async throws {
        guard let roomJID = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        try await mucModule.kickOccupant(nickname: nickname, from: roomJID, reason: reason)
    }

    public func banUser(jidString: String, fromRoomJIDString roomJIDString: String, reason: String?, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        guard let roomJID = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        try await mucModule.banUser(jid: jid, from: roomJID, reason: reason)
    }

    public func grantVoice(nickname: String, inRoomJIDString roomJIDString: String, accountID: UUID) async throws {
        guard let roomJID = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        try await mucModule.grantVoice(nickname: nickname, in: roomJID)
    }

    public func revokeVoice(nickname: String, inRoomJIDString roomJIDString: String, accountID: UUID) async throws {
        guard let roomJID = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        try await mucModule.revokeVoice(nickname: nickname, in: roomJID)
    }

    public func changeRoomNickname(jidString: String, newNickname: String, accountID: UUID) async throws {
        guard let roomJID = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        try await mucModule.changeNickname(in: roomJID, to: newNickname)
    }

    public func getRoomConfig(jidString: String, accountID: UUID) async throws -> [RoomConfigField] {
        guard let roomJID = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        guard let client = accountService?.client(for: accountID) else { return [] }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return [] }
        let fields = try await mucModule.getRoomConfig(roomJID)
        return fields.map { RoomConfigField(from: $0) }
    }

    public func submitRoomConfig(jidString: String, fields: [RoomConfigField], accountID: UUID) async throws {
        guard let roomJID = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        let dataFormFields = fields.map { $0.toDataFormField() }
        try await mucModule.submitRoomConfig(roomJID, fields: dataFormFields)
    }

    public func getAffiliationList(
        affiliation: RoomAffiliation,
        inRoomJIDString roomJIDString: String,
        accountID: UUID
    ) async throws -> [RoomAffiliationItem] {
        guard let roomJID = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        guard let client = accountService?.client(for: accountID) else { return [] }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return [] }
        let mucAff = MUCAffiliation(rawValue: affiliation.rawValue) ?? .none
        let items = try await mucModule.getAffiliationList(mucAff, in: roomJID)
        return items.map { RoomAffiliationItem(jidString: $0.jid.description, affiliation: RoomAffiliation(rawValue: $0.affiliation.rawValue) ?? .none, nickname: $0.nickname, reason: $0.reason) }
    }

    public func setAffiliation(
        jidString: String,
        inRoomJIDString roomJIDString: String,
        to affiliation: RoomAffiliation,
        reason: String? = nil,
        accountID: UUID
    ) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        guard let roomJID = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        let mucAff = MUCAffiliation(rawValue: affiliation.rawValue) ?? .none
        try await mucModule.setAffiliation(jid: jid, in: roomJID, to: mucAff, reason: reason)
    }

    public func destroyRoom(jidString: String, reason: String? = nil, accountID: UUID) async throws {
        guard let roomJID = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        try await mucModule.destroyRoom(roomJID, reason: reason)
    }

    public func acceptInvite(_ invite: PendingRoomInvite, nickname: String, accountID: UUID) async throws {
        try await joinRoom(jidString: invite.roomJIDString, nickname: nickname, password: invite.password, accountID: accountID)
        pendingInvites.removeAll { $0.id == invite.id }
    }

    public func declineInvite(_ invite: PendingRoomInvite, reason: String? = nil, accountID: UUID) async throws {
        // XEP-0249 direct invites have no decline mechanism — only send decline for mediated invites
        if !invite.isDirect,
           let roomJID = BareJID.parse(invite.roomJIDString),
           let fromString = invite.fromJIDString,
           let inviterJID = JID.parse(fromString),
           let client = accountService?.client(for: accountID),
           let mucModule = await client.module(ofType: MUCModule.self) {
            try await mucModule.declineInvite(room: roomJID, inviter: inviterJID, reason: reason)
        }
        pendingInvites.removeAll { $0.id == invite.id }
    }

    public func clearNewlyCreatedRoom(_ jidString: String) {
        newlyCreatedRoomJIDs.remove(jidString)
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
        case encryptionFailed(String)
        case notOutgoingMessage

        public var errorDescription: String? {
            switch self {
            case let .invalidJID(string): "Invalid JID: \(string)"
            case let .encryptionFailed(reason): "Encryption failed: \(reason)"
            case .notOutgoingMessage: "Cannot correct a message that was not sent by you"
            }
        }
    }

    // MARK: - Event Handling

    func handleEvent(_ event: XMPPEvent, accountID: UUID) async {
        switch event {
        case let .messageReceived(xmppMessage):
            await handleMessageReceived(xmppMessage, accountID: accountID)
        case .messageCarbonReceived, .messageCarbonSent:
            await handleCarbonEvent(event, accountID: accountID)
        case let .deliveryReceiptReceived(messageID, _):
            await handleDeliveryReceipt(messageID: messageID)
        case let .chatMarkerReceived(messageID, markerType, _):
            await handleChatMarker(messageID: messageID, type: markerType)
        case let .chatStateChanged(from, chatState):
            handleChatStateChanged(from: from, state: chatState)
        case .messageCorrected, .messageRetracted:
            await handleMessageUpdateEvent(event, accountID: accountID)
        case .messageModerated, .messageError:
            await handleMessageUpdateEvent(event, accountID: accountID)
        case .rosterLoaded:
            Task { [weak self] in
                await self?.syncRecentHistory(accountID: accountID)
            }
        case .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged, .roomSubjectChanged,
             .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived, .roomDestroyed,
             .mucSelfPingFailed, .disconnected:
            await handleMUCEvent(event, accountID: accountID)
        case .connected, .streamResumed, .authenticationFailed,
             .presenceReceived, .iqReceived,
             .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .archivedMessagesLoaded,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced:
            break
        }
    }

    private func handleMUCEvent(_ event: XMPPEvent, accountID: UUID) async {
        switch event {
        case let .roomJoined(room, occupancy, isNewlyCreated):
            await handleRoomJoined(room: room, occupancy: occupancy, isNewlyCreated: isNewlyCreated, accountID: accountID)
        case .roomOccupantJoined, .roomOccupantLeft, .roomOccupantNickChanged:
            handleMUCOccupantEvent(event, accountID: accountID)
        case let .roomMessageReceived(xmppMessage):
            await handleRoomMessageReceived(xmppMessage, accountID: accountID)
        case let .mucPrivateMessageReceived(xmppMessage):
            await handleMUCPrivateMessageReceived(xmppMessage, accountID: accountID)
        case let .roomSubjectChanged(room, subject, _):
            await handleRoomSubjectChanged(room: room, subject: subject, accountID: accountID)
        case let .roomInviteReceived(invite):
            handleRoomInviteReceived(invite)
        case let .roomDestroyed(room, _, _):
            handleRoomDestroyed(room: room)
        case let .mucSelfPingFailed(room, reason):
            await handleMUCSelfPingFailed(room: room, reason: reason, accountID: accountID)
        case .disconnected:
            newlyCreatedRoomJIDs.removeAll()
            roomFlags.removeAll()
        case .connected, .streamResumed, .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced:
            break
        }
    }

    private func handleMUCOccupantEvent(_ event: XMPPEvent, accountID: UUID) {
        switch event {
        case let .roomOccupantJoined(room, occupant):
            handleRoomOccupantJoined(room: room, occupant: occupant)
        case let .roomOccupantLeft(room, occupant, _):
            handleRoomOccupantLeft(room: room, occupant: occupant)
        case let .roomOccupantNickChanged(room, oldNickname, occupant):
            handleRoomOccupantNickChanged(room: room, oldNickname: oldNickname, occupant: occupant, accountID: accountID)
        case .connected, .streamResumed, .disconnected, .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .roomJoined, .roomSubjectChanged,
             .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived,
             .roomDestroyed, .mucSelfPingFailed,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced:
            break
        }
    }

    private func handleMUCSelfPingFailed(room: BareJID, reason: MUCSelfPingFailure, accountID: UUID) async {
        switch reason {
        case .notJoined:
            log.warning("MUC self-ping: not joined \(room), triggering rejoin")
            let conversation = await (try? store.fetchConversation(jid: room.description, type: .groupchat, accountID: accountID))
            let nickname = conversation?.roomNickname ?? room.localPart ?? "user"
            do {
                try await joinRoom(jid: room, nickname: nickname, accountID: accountID)
            } catch {
                log.warning("MUC self-ping rejoin failed for \(room): \(error)")
            }
        case .nickChanged:
            break
        }
    }

    private func handleCarbonEvent(_ event: XMPPEvent, accountID: UUID) async {
        switch event {
        case let .messageCarbonReceived(forwarded):
            await handleCarbon(forwarded, accountID: accountID, isOutgoing: false)
        case let .messageCarbonSent(forwarded):
            await handleCarbon(forwarded, accountID: accountID, isOutgoing: true)
        case .connected, .streamResumed, .disconnected, .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged,
             .roomSubjectChanged, .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived,
             .roomDestroyed, .mucSelfPingFailed,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced:
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

    /// Returns `true` if the element contained a receipt or chat marker that was handled.
    private func handleCarbonReceiptOrMarker(_ element: DuckoXMPP.XMLElement) async -> Bool {
        if let received = element.child(named: "received", namespace: XMPPNamespaces.receipts),
           let messageID = received.attribute("id") {
            await handleDeliveryReceipt(messageID: messageID)
            return true
        }
        for markerType in ChatMarkerType.allCases {
            if let marker = element.child(named: markerType.rawValue, namespace: XMPPNamespaces.chatMarkers),
               let messageID = marker.attribute("id") {
                await handleChatMarker(messageID: messageID, type: markerType)
                return true
            }
        }
        return false
    }

    private func handleChatStateChanged(from: BareJID, state: ChatState) {
        typingStates[from] = state
    }

    private func handleMessageCorrected(originalID: String, newBody: String, from: JID, accountID: UUID) async {
        guard let original = try? await store.fetchMessageByStanzaID(originalID) else { return }
        guard await verifySender(from: from, original: original, action: "correction", accountID: accountID) else { return }

        try? await store.updateMessageBody(stanzaID: originalID, newBody: newBody, isEdited: true, editedAt: Date())
        await reloadActiveMessages()
    }

    private func handleMessageRetracted(originalID: String, from: JID, accountID: UUID) async {
        guard let original = try? await store.fetchMessageByStanzaID(originalID) else { return }
        guard await verifySender(from: from, original: original, action: "retraction", accountID: accountID) else { return }

        try? await store.markMessageRetracted(stanzaID: originalID, retractedAt: Date())
        await reloadActiveMessages()
    }

    private func verifySender(from: JID, original: ChatMessage, action: String, accountID: UUID) async -> Bool {
        if original.type == "groupchat" {
            // MUC: verify sender nickname matches
            guard case let .full(fullJID) = from else {
                log.warning("Rejected MUC \(action) without full JID: \(from)")
                return false
            }
            let senderNickname = fullJID.resourcePart
            if original.isOutgoing {
                // Echo of our own message — verify it's from our nickname
                guard await isOwnRoomMessage(nickname: senderNickname, room: from.bareJID, accountID: accountID) else {
                    log.warning("Rejected MUC \(action) for own message from wrong sender: \(senderNickname)")
                    return false
                }
            } else {
                // Incoming — sender nickname must match original
                guard senderNickname == original.fromJID else {
                    log.warning("Rejected MUC \(action): nickname \(senderNickname) != original \(original.fromJID)")
                    return false
                }
            }
        } else {
            // 1:1 chat: only the original sender can correct/retract their own message.
            // Outgoing messages store the recipient as fromJID — reject any remote
            // correction/retraction targeting our own outgoing messages.
            if original.isOutgoing {
                log.warning("Rejected \(action) targeting outgoing 1:1 message")
                return false
            }
            let senderJID = from.bareJID.description
            guard senderJID == original.fromJID else {
                log.warning("Rejected \(action): sender \(senderJID) doesn't match original \(original.fromJID)")
                return false
            }
        }
        return true
    }

    private func handleMessageUpdateEvent(_ event: XMPPEvent, accountID: UUID) async {
        switch event {
        case let .messageCorrected(originalID, newBody, from):
            await handleMessageCorrected(originalID: originalID, newBody: newBody, from: from, accountID: accountID)
        case let .messageRetracted(originalID, from):
            await handleMessageRetracted(originalID: originalID, from: from, accountID: accountID)
        case let .messageModerated(originalID, _, _, _):
            try? await store.markMessageRetractedByServerID(originalID, retractedAt: Date())
        case let .messageError(messageID, _, error):
            await handleMessageError(messageID: messageID, errorText: error.displayText)
            return
        case .connected, .streamResumed, .disconnected, .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived, .chatMarkerReceived,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged, .roomSubjectChanged,
             .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived, .roomDestroyed,
             .mucSelfPingFailed,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced:
            return
        }
        await reloadActiveMessages()
    }

    private func handleMessageError(messageID: String?, errorText: String) async {
        guard let messageID else { return }
        try? await store.updateMessageError(stanzaID: messageID, errorText: errorText)
        await reloadActiveMessages()
    }

    private func handleRoomJoined(room: BareJID, occupancy: RoomOccupancy, isNewlyCreated: Bool, accountID: UUID) async {
        _ = try? await findOrCreateGroupConversation(for: room, nickname: occupancy.nickname, accountID: accountID)
        let key = room.description
        roomParticipants[key] = occupancy.occupants.map { mapOccupant($0) }
        if isNewlyCreated {
            newlyCreatedRoomJIDs.insert(key)
        }
        if occupancy.flags.isEmpty {
            roomFlags.removeValue(forKey: key)
        } else {
            roomFlags[key] = occupancy.flags
        }
    }

    private func handleRoomOccupantJoined(room: BareJID, occupant: RoomOccupant) {
        let key = room.description
        let participant = mapOccupant(occupant)
        var list = roomParticipants[key] ?? []
        list.removeAll { $0.nickname == participant.nickname }
        list.append(participant)
        roomParticipants[key] = list
    }

    private func handleRoomOccupantLeft(room: BareJID, occupant: RoomOccupant) {
        let key = room.description
        roomParticipants[key]?.removeAll { $0.nickname == occupant.nickname }
    }

    private func handleRoomInviteReceived(_ invite: RoomInvite) {
        let pending = PendingRoomInvite(
            roomJIDString: invite.room.description,
            fromJIDString: invite.from.description,
            reason: invite.reason,
            password: invite.password,
            isDirect: invite.isDirect
        )
        // Deduplicate by room+from
        guard !pendingInvites.contains(where: { $0.roomJIDString == pending.roomJIDString && $0.fromJIDString == pending.fromJIDString }) else {
            return
        }
        pendingInvites.append(pending)
    }

    private func isOwnRoomMessage(nickname: String?, room: BareJID, accountID: UUID) async -> Bool {
        guard let nickname,
              let client = accountService?.client(for: accountID),
              let mucModule = await client.module(ofType: MUCModule.self) else { return false }
        return nickname == mucModule.nickname(in: room)
    }

    private func handleRoomMessageReceived(_ xmppMessage: XMPPMessage, accountID: UUID) async {
        let oobAttachments = parseOOBAttachments(from: xmppMessage.element)
        guard let from = xmppMessage.from else { return }

        // Accept messages with body or OOB attachments
        let body = xmppMessage.body ?? oobAttachments.first?.url
        guard let body else { return }

        let roomJID = from.bareJID

        let senderNickname: String? = if case let .full(fullJID) = from {
            fullJID.resourcePart
        } else {
            nil
        }

        // Skip own messages (the server echoes them back)
        if await isOwnRoomMessage(nickname: senderNickname, room: roomJID, accountID: accountID) {
            return
        }

        // Deduplicate replayed stanzas (stream recovery, MAM catchup)
        if await isDuplicate(stanzaID: xmppMessage.id, from: roomJID, accountID: accountID) {
            return
        }

        let conversation: Conversation
        do {
            conversation = try await findOrCreateGroupConversation(for: roomJID, nickname: nil, accountID: accountID)
        } catch {
            return
        }

        let content = MessageContent(body: body, isUnstyled: xmppMessage.isUnstyled)
        let filterContext = FilterContext(accountJID: accountJID(for: accountID, fallback: roomJID))
        let filtered = await filterPipeline.process(content, direction: .incoming, context: filterContext)

        // Parse XEP-0359 stanza-id assigned by the MUC server
        let serverID: String? = xmppMessage.element.children(named: "stanza-id")
            .first(where: { $0.namespace == XMPPNamespaces.stanzaID && $0.attribute("by") == roomJID.description })
            .flatMap { $0.attribute("id") }

        let fromLabel = senderNickname ?? roomJID.description
        let message = ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            stanzaID: xmppMessage.id,
            serverID: serverID,
            fromJID: fromLabel,
            body: filtered.body,
            htmlBody: filtered.htmlBody,
            timestamp: Date(),
            isOutgoing: false,
            isRead: false,
            isDelivered: false,
            isEdited: false,
            type: "groupchat",
            attachments: oobAttachments
        )
        await persistAndNotify(message, in: conversation, accountID: accountID)
    }

    private func handleMUCPrivateMessageReceived(_ xmppMessage: XMPPMessage, accountID: UUID) async {
        guard let from = xmppMessage.from,
              case let .full(fullJID) = from,
              let body = xmppMessage.body else { return }
        let roomJID = fullJID.bareJID
        let nickname = fullJID.resourcePart

        if await isDuplicate(stanzaID: xmppMessage.id, from: roomJID, occupantNickname: nickname, accountID: accountID) {
            return
        }

        let conversation: Conversation
        do {
            conversation = try await findOrCreateMUCPMConversation(for: roomJID, nickname: nickname, accountID: accountID)
        } catch {
            log.warning("Failed to create MUC PM conversation for \(roomJID)/\(nickname): \(error)")
            return
        }

        let content = MessageContent(body: body, isUnstyled: xmppMessage.isUnstyled)
        let filterContext = FilterContext(accountJID: accountJID(for: accountID, fallback: roomJID))
        let filtered = await filterPipeline.process(content, direction: .incoming, context: filterContext)

        let message = ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            stanzaID: xmppMessage.id,
            fromJID: nickname,
            body: filtered.body,
            htmlBody: filtered.htmlBody,
            timestamp: Date(),
            isOutgoing: false,
            isRead: false,
            isDelivered: false,
            isEdited: false,
            type: "chat"
        )
        await persistAndNotify(message, in: conversation, accountID: accountID)
    }

    private func findOrCreateMUCPMConversation(
        for roomJID: BareJID, nickname: String, accountID: UUID
    ) async throws -> Conversation {
        let conversations = try await store.fetchConversations(for: accountID)
        if let existing = conversations.first(where: {
            $0.jid == roomJID && $0.type == .chat && $0.occupantNickname == nickname
        }) {
            return existing
        }
        let conversation = Conversation(
            id: UUID(),
            accountID: accountID,
            jid: roomJID,
            type: .chat,
            displayName: nickname,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            occupantNickname: nickname,
            createdAt: Date()
        )
        try await store.upsertConversation(conversation)
        return conversation
    }

    private func persistAndNotify(_ message: ChatMessage, in conversation: Conversation, accountID: UUID) async {
        let isActiveConversation = conversation.id == activeConversationID
        try? await persistMessage(message, in: conversation, incrementUnread: !isActiveConversation, accountID: accountID)

        if isActiveConversation {
            try? await store.markMessagesRead(in: conversation.id)
            await sendDisplayedMarkerIfNeeded(for: message, in: conversation, accountID: accountID)
        }

        onIncomingMessage?(message, conversation)
    }

    private func handleRoomSubjectChanged(room: BareJID, subject: String?, accountID: UUID) async {
        let conversations = await (try? store.fetchConversations(for: accountID)) ?? []
        guard var conversation = conversations.first(where: { $0.jid == room && $0.type == .groupchat }) else { return }
        conversation.roomSubject = subject
        try? await store.upsertConversation(conversation)
        if let index = openConversations.firstIndex(where: { $0.id == conversation.id }) {
            openConversations[index] = conversation
        }
    }

    private func handleRoomOccupantNickChanged(room: BareJID, oldNickname: String, occupant: RoomOccupant, accountID: UUID) {
        let key = room.description
        var list = roomParticipants[key] ?? []
        let participant = mapOccupant(occupant)
        list.removeAll { $0.nickname == oldNickname || $0.nickname == participant.nickname }
        list.append(participant)
        roomParticipants[key] = list

        // If self-nick changed, update conversation
        if let conversation = openConversations.first(where: { $0.jid == room && $0.type == .groupchat }),
           conversation.roomNickname == oldNickname {
            Task {
                var updated = conversation
                updated.roomNickname = occupant.nickname
                try? await store.upsertConversation(updated)
                openConversations = await (try? store.fetchConversations(for: accountID)) ?? openConversations
            }
        }
    }

    private func handleRoomDestroyed(room: BareJID) {
        roomParticipants.removeValue(forKey: room.description)
    }

    // MARK: - Private: Group OMEMO

    /// Attempts OMEMO encryption for a group message. Returns `true` if encrypted.
    private func encryptAndSendGroupMessage(
        room: BareJID, body: String, stanzaID: String,
        conversation: Conversation, mucModule: MUCModule,
        additionalElements: [DuckoXMPP.XMLElement] = []
    ) async throws -> Bool {
        guard conversation.encryptionEnabled, let omemoService else {
            try await mucModule.sendMessage(to: room, body: body, id: stanzaID, markable: true, additionalElements: additionalElements)
            return false
        }

        let memberJIDs = try await roomMemberJIDs(roomJIDString: room.description, accountID: conversation.accountID)
        guard !memberJIDs.isEmpty else {
            throw ChatServiceError.encryptionFailed("Cannot encrypt: no room members with known JIDs")
        }

        let elements = try await omemoService.encryptGroupMessage(
            body: body, roomJID: room, memberJIDs: memberJIDs, accountID: conversation.accountID
        )
        let storeHint = DuckoXMPP.XMLElement(name: "store", namespace: XMPPNamespaces.processingHints)
        try await mucModule.sendMessage(
            to: room, body: elements.fallbackBody, id: stanzaID, markable: true,
            additionalElements: [elements.encrypted, elements.encryption, storeHint] + additionalElements
        )
        return true
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
        if shouldSkipRawMessage(xmppMessage) { return }

        // Headline messages are transient (RFC 6121 §5.2.2) — surface but don't persist
        if xmppMessage.messageType == .headline {
            if xmppMessage.body != nil, xmppMessage.from != nil {
                onHeadlineMessage?(xmppMessage)
            }
            return
        }

        // Parse OOB attachments before body check — OOB-only messages have no body
        let oobAttachments = parseOOBAttachments(from: xmppMessage.element)

        guard xmppMessage.messageType == .chat || xmppMessage.messageType == .normal,
              let fromJID = xmppMessage.from?.bareJID else { return }

        // Accept messages with body or OOB attachments
        let body = xmppMessage.body ?? oobAttachments.first?.url
        guard let body else { return }

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

        let content = MessageContent(body: body, isUnstyled: xmppMessage.isUnstyled)
        let filterContext = FilterContext(accountJID: accountJID(for: accountID, fallback: fromJID))
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
            replyToID: replyToID,
            attachments: oobAttachments
        )
        await persistAndNotify(message, in: conversation, accountID: accountID)
    }

    private func handleCarbon(_ forwarded: ForwardedMessage, accountID: UUID, isOutgoing: Bool) async {
        let jid = isOutgoing ? forwarded.message.to?.bareJID : forwarded.message.from?.bareJID
        let oobAttachments = parseOOBAttachments(from: forwarded.message.element)

        guard forwarded.message.messageType != .groupchat,
              let jid else { return }

        // Handle receipt/marker carbons (bodyless) before the body guard.
        // Carbon-forwarded stanzas bypass ReceiptsModule dispatch, so parse XML directly.
        if await handleCarbonReceiptOrMarker(forwarded.message.element) {
            return
        }

        // Accept messages with body or OOB attachments
        let body = forwarded.message.body ?? oobAttachments.first?.url
        guard let body else { return }

        // Skip retractions — handled by .messageRetracted event
        if forwarded.message.element.child(named: "retract", namespace: XMPPNamespaces.messageRetract) != nil {
            return
        }

        // Skip corrections — handled by .messageCorrected event
        if forwarded.message.element.child(named: "replace", namespace: XMPPNamespaces.messageCorrect) != nil {
            return
        }

        // Skip encrypted messages — handled by .omemoEncryptedMessageReceived event
        if forwarded.message.element.child(named: "encryption", namespace: XMPPNamespaces.eme) != nil {
            return
        }

        if await isDuplicate(stanzaID: forwarded.message.id, from: jid, accountID: accountID) {
            return
        }

        let conversation: Conversation
        do {
            conversation = try await findOrCreateConversation(for: jid, accountID: accountID)
        } catch {
            return
        }

        let content = MessageContent(body: body, isUnstyled: forwarded.message.isUnstyled)
        let filterDirection: FilterDirection = isOutgoing ? .outgoing : .incoming
        let filterContext = FilterContext(accountJID: accountJID(for: accountID, fallback: jid))
        let filtered = await filterPipeline.process(content, direction: filterDirection, context: filterContext)

        let timestamp = parseISO8601Timestamp(forwarded.timestamp)

        let message = ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            stanzaID: forwarded.message.id,
            fromJID: jid.description,
            body: filtered.body,
            htmlBody: filtered.htmlBody,
            timestamp: timestamp,
            isOutgoing: isOutgoing,
            isRead: true,
            isDelivered: false,
            isEdited: false,
            type: "chat",
            attachments: oobAttachments
        )
        try? await persistMessage(message, in: conversation, accountID: accountID)
    }

    private func parseISO8601Timestamp(_ stamp: String?) -> Date {
        guard let stamp else { return Date() }
        let isoStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let basicStyle = Date.ISO8601FormatStyle()
        return (try? isoStyle.parse(stamp)) ?? (try? basicStyle.parse(stamp)) ?? Date()
    }

    /// Parses XEP-0066 `<x xmlns='jabber:x:oob'>` elements into attachments.
    /// Returns `true` if the raw `.messageReceived` stanza should be skipped because a classified event handles it.
    private func shouldSkipRawMessage(_ message: XMPPMessage) -> Bool {
        // Retractions, corrections, encrypted — handled by classified events
        if message.element.child(named: "retract", namespace: XMPPNamespaces.messageRetract) != nil { return true }
        if message.element.child(named: "replace", namespace: XMPPNamespaces.messageCorrect) != nil { return true }
        if message.element.child(named: "encryption", namespace: XMPPNamespaces.eme) != nil { return true }
        // MUC invites — handled by .roomInviteReceived
        if message.element.child(named: "x", namespace: XMPPNamespaces.mucDirectInvite) != nil { return true }
        if let mucUser = message.element.child(named: "x", namespace: XMPPNamespaces.mucUser),
           mucUser.child(named: "invite") != nil { return true }
        // MUC private messages — handled by .mucPrivateMessageReceived
        if message.messageType == .chat || message.messageType == .normal, let from = message.from, case .full = from {
            let roomJID = from.bareJID
            if openConversations.contains(where: { $0.jid == roomJID && $0.type == .groupchat })
                || message.element.child(named: "x", namespace: XMPPNamespaces.mucUser) != nil {
                return true
            }
        }
        return false
    }

    private func parseOOBAttachments(from element: DuckoXMPP.XMLElement) -> [Attachment] {
        element.children(named: "x")
            .filter { $0.namespace == XMPPNamespaces.oob }
            .compactMap { oob -> Attachment? in
                guard let urlString = oob.child(named: "url")?.textContent, !urlString.isEmpty else { return nil }
                let desc = oob.child(named: "desc")?.textContent
                let fileName = URL(string: urlString)?.lastPathComponent
                return Attachment(id: UUID(), url: urlString, fileName: fileName, oobDescription: desc)
            }
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

    private func isDuplicate(stanzaID: String?, from jid: BareJID, occupantNickname: String? = nil, accountID: UUID) async -> Bool {
        guard let stanzaID else { return false }
        guard let conversation = openConversations.first(where: {
            $0.jid == jid && $0.accountID == accountID &&
                (occupantNickname == nil || $0.occupantNickname == occupantNickname)
        }) else {
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

    public func searchMessages(
        for conversationID: UUID,
        query: String,
        limit: Int = 100
    ) async throws -> [ChatMessage] {
        let messages = try await store.fetchMessages(for: conversationID, before: nil, limit: 500)
        return messages
            .filter { $0.body.localizedStandardContains(query) }
            .prefix(limit)
            .reversed()
    }

    public func fetchServerHistory(
        jid: BareJID,
        accountID: UUID,
        before: Date?,
        limit: Int
    ) async throws -> (messages: [ChatMessage], hasMore: Bool) {
        guard let client = accountService?.client(for: accountID) else {
            return ([], false)
        }
        guard let mamModule = await client.module(ofType: MAMModule.self) else {
            return ([], false)
        }

        let conversation = try await findOrCreateConversation(for: jid, accountID: accountID)
        let accountJID = accountJID(for: accountID, fallback: jid)
        let endISO = before.map { $0.formatted(.iso8601) }

        let to: BareJID? = conversation.type == .groupchat ? conversation.jid : nil
        let with: BareJID? = conversation.type == .groupchat ? nil : jid
        let (archived, fin) = try await mamModule.queryMessages(to: to, with: with, end: endISO, max: limit)
        let newMessages = try await convertAndDedup(
            archived: archived, conversation: conversation, accountJID: accountJID
        )
        return (newMessages, !fin.complete)
    }

    public func fetchServerHistory(
        jidString: String,
        accountID: UUID,
        before: Date?,
        limit: Int
    ) async throws -> (messages: [ChatMessage], hasMore: Bool) {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        return try await fetchServerHistory(jid: jid, accountID: accountID, before: before, limit: limit)
    }

    private func syncRecentHistory(accountID: UUID) async {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let mamModule = await client.module(ofType: MAMModule.self) else { return }
        guard let account = accountService?.accounts.first(where: { $0.id == accountID }) else { return }
        let accountJID = account.jid

        do {
            let conversations = try await store.fetchConversations(for: accountID)
            for conversation in conversations {
                let lastMessages = try await store.fetchMessages(for: conversation.id, before: nil, limit: 1)
                let startISO = lastMessages.first.map { $0.timestamp.formatted(.iso8601) }

                let to: BareJID? = conversation.type == .groupchat ? conversation.jid : nil
                let with: BareJID? = conversation.type == .groupchat ? nil : conversation.jid
                let (archived, _) = try await mamModule.queryMessages(
                    to: to, with: with, start: startISO, max: 50
                )
                let newMessages = try await convertAndDedup(
                    archived: archived, conversation: conversation, accountJID: accountJID
                )
                if let lastMessage = newMessages.last {
                    var updated = conversation
                    updated.lastMessageDate = lastMessage.timestamp
                    updated.lastMessagePreview = String(lastMessage.body.prefix(100))
                    try await store.upsertConversation(updated)
                }
            }
            openConversations = try await store.fetchConversations(for: accountID)
        } catch {
            let desc = error.localizedDescription
            log.warning("MAM sync failed: \(desc)")
        }
    }

    private func convertAndDedup(
        archived: [ArchivedMessage],
        conversation: Conversation,
        accountJID: BareJID
    ) async throws -> [ChatMessage] {
        var newMessages: [ChatMessage] = []

        for entry in archived {
            let forwarded = entry.forwarded
            guard let body = forwarded.message.body else { continue }

            if let serverID = entry.serverID {
                if try await store.messageExistsByServerID(serverID, conversationID: conversation.id) {
                    continue
                }
            } else if let stanzaID = forwarded.message.id {
                if try await store.messageExistsByStanzaID(stanzaID, conversationID: conversation.id) {
                    continue
                }
            }

            let timestamp = parseISO8601Timestamp(forwarded.timestamp)

            let meta = resolveMessageMeta(forwarded: forwarded, conversation: conversation, accountJID: accountJID)

            let message = ChatMessage(
                id: UUID(),
                conversationID: conversation.id,
                stanzaID: forwarded.message.id,
                serverID: entry.serverID,
                fromJID: meta.fromJID,
                body: body,
                timestamp: timestamp,
                isOutgoing: meta.isOutgoing,
                isRead: true,
                isDelivered: false,
                isEdited: false,
                type: meta.messageType
            )
            try await store.insertMessage(message)
            newMessages.append(message)
        }

        return newMessages.sorted { $0.timestamp < $1.timestamp }
    }

    private struct MessageMeta {
        let fromJID: String
        let isOutgoing: Bool
        let messageType: String
    }

    private func resolveMessageMeta(
        forwarded: ForwardedMessage,
        conversation: Conversation,
        accountJID: BareJID
    ) -> MessageMeta {
        switch conversation.type {
        case .groupchat:
            // MUC: extract nickname from resource part
            let senderNickname: String? = if case let .full(fullJID) = forwarded.message.from {
                fullJID.resourcePart
            } else {
                nil
            }
            return MessageMeta(
                fromJID: senderNickname ?? conversation.jid.description,
                isOutgoing: senderNickname != nil && senderNickname == conversation.roomNickname,
                messageType: conversation.type.rawValue
            )
        case .chat:
            // 1:1 chat: compare bare JIDs
            return MessageMeta(
                fromJID: forwarded.message.from?.bareJID.description ?? accountJID.description,
                isOutgoing: forwarded.message.from?.bareJID == accountJID,
                messageType: forwarded.message.messageType?.rawValue ?? "chat"
            )
        }
    }

    private func mapOccupant(_ occupant: RoomOccupant) -> RoomParticipant {
        let affiliation = RoomAffiliation(rawValue: occupant.affiliation.rawValue) ?? .none
        let role = RoomRole(rawValue: occupant.role.rawValue) ?? .none
        return RoomParticipant(
            nickname: occupant.nickname,
            jidString: occupant.jid?.description,
            affiliation: affiliation,
            role: role
        )
    }

    private func findOrCreateConversation(for jid: BareJID, accountID: UUID) async throws -> Conversation {
        let conversations = try await store.fetchConversations(for: accountID)
        if let existing = conversations.first(where: { $0.jid == jid && $0.occupantNickname == nil }) {
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
            encryptionEnabled: OMEMOPreferences.shared.encryptByDefault,
            createdAt: Date()
        )
        try await store.upsertConversation(conversation)
        return conversation
    }

    private func findOrCreateGroupConversation(
        for room: BareJID,
        nickname: String?,
        accountID: UUID
    ) async throws -> Conversation {
        let conversations = try await store.fetchConversations(for: accountID)
        if var existing = conversations.first(where: { $0.jid == room && $0.type == .groupchat }) {
            if let nickname, existing.roomNickname != nickname {
                existing.roomNickname = nickname
                try await store.upsertConversation(existing)
            }
            return existing
        }

        let conversation = Conversation(
            id: UUID(),
            accountID: accountID,
            jid: room,
            type: .groupchat,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            roomNickname: nickname,
            encryptionEnabled: OMEMOPreferences.shared.encryptByDefault,
            createdAt: Date()
        )
        try await store.upsertConversation(conversation)
        return conversation
    }
}
