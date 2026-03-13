import DuckoXMPP
import Foundation
import os

private let log = Logger(subsystem: "com.ducko.core", category: "chat")

@MainActor @Observable
public final class ChatService {
    public private(set) var openConversations: [Conversation] = []
    public private(set) var activeConversationID: UUID?
    public private(set) var messages: [ChatMessage] = []
    public private(set) var typingStates: [BareJID: ChatState] = [:]
    public private(set) var roomParticipants: [String: [RoomParticipant]] = [:]
    public private(set) var pendingInvites: [PendingRoomInvite] = []
    public private(set) var newlyCreatedRoomJIDs: Set<String> = []
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
        let filterContext = FilterContext(accountJID: accountJID(for: accountID, fallback: jid))
        let filtered = await filterPipeline.process(content, direction: .outgoing, context: filterContext)

        let recipient = JID.bare(jid)
        let stanzaID = client.generateID()
        let chatStatesEnabled = ChatPreferences.shared.enableChatStates
        try await chatModule.sendMessage(to: recipient, body: filtered.body, id: stanzaID, requestReceipt: true, includeChatState: chatStatesEnabled)

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
        guard let client = accountService?.client(for: accountID) else { return }
        guard let chatModule = await client.module(ofType: ChatModule.self) else { return }

        let chatStatesEnabled = ChatPreferences.shared.enableChatStates
        try await chatModule.sendCorrection(to: .bare(jid), body: newBody, replacingID: originalStanzaID, includeChatState: chatStatesEnabled)
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
        accountID: UUID
    ) async throws {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let module = await client.module(ofType: ReceiptsModule.self) else { return }
        try await module.sendDisplayedMarker(to: .bare(jid), messageID: messageStanzaID)
    }

    // MARK: - Private: Displayed Markers

    private func sendDisplayedMarkerForLatest(conversationID: UUID, accountID: UUID) async {
        guard let conversation = openConversations.first(where: { $0.id == conversationID }),
              conversation.type == .chat else { return }
        let latestIncoming = messages.last { !$0.isOutgoing && $0.stanzaID != nil }
        guard let stanzaID = latestIncoming?.stanzaID else { return }
        try? await sendDisplayedMarker(to: conversation.jid, messageStanzaID: stanzaID, accountID: accountID)
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

    public func sendGroupMessage(to room: BareJID, body: String, accountID: UUID) async throws {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }

        let stanzaID = client.generateID()
        try await mucModule.sendMessage(to: room, body: body, id: stanzaID)

        // Persist outgoing group message
        let conversation = try await findOrCreateGroupConversation(for: room, nickname: nil, accountID: accountID)

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
            type: "groupchat"
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

    public func setRoomSubject(jidString: String, subject: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        try await mucModule.setSubject(in: jid, subject: subject)
    }

    public func inviteUser(jidString: String, toRoomJIDString roomJIDString: String, reason: String?, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        guard let roomJID = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        try await mucModule.inviteUser(jid, to: roomJID, reason: reason)
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

    public func declineInvite(_ invite: PendingRoomInvite) {
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
        case .messageCarbonReceived, .messageCarbonSent:
            await handleCarbonEvent(event, accountID: accountID)
        case let .deliveryReceiptReceived(messageID, _):
            await handleDeliveryReceipt(messageID: messageID)
        case let .chatMarkerReceived(messageID, markerType, _):
            await handleChatMarker(messageID: messageID, type: markerType)
        case let .chatStateChanged(from, chatState):
            handleChatStateChanged(from: from, state: chatState)
        case let .messageCorrected(originalID, newBody, _):
            await handleMessageCorrected(originalID: originalID, newBody: newBody)
        case let .messageError(messageID, _, error):
            await handleMessageError(messageID: messageID, errorText: error.displayText)
        case .rosterLoaded:
            Task { [weak self] in
                await self?.syncRecentHistory(accountID: accountID)
            }
        case .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged, .roomSubjectChanged,
             .roomInviteReceived, .roomMessageReceived, .roomDestroyed,
             .mucSelfPingFailed, .disconnected:
            await handleMUCEvent(event, accountID: accountID)
        case .connected, .streamResumed, .authenticationFailed,
             .presenceReceived, .iqReceived,
             .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .archivedMessagesLoaded,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .blockListLoaded, .contactBlocked, .contactUnblocked:
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
        case .connected, .streamResumed, .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .blockListLoaded, .contactBlocked, .contactUnblocked:
            break
        }
    }

    private func handleMUCOccupantEvent(_ event: XMPPEvent, accountID: UUID) {
        switch event {
        case let .roomOccupantJoined(room, occupant):
            handleRoomOccupantJoined(room: room, occupant: occupant)
        case let .roomOccupantLeft(room, occupant):
            handleRoomOccupantLeft(room: room, occupant: occupant)
        case let .roomOccupantNickChanged(room, oldNickname, occupant):
            handleRoomOccupantNickChanged(room: room, oldNickname: oldNickname, occupant: occupant, accountID: accountID)
        case .connected, .streamResumed, .disconnected, .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .roomJoined, .roomSubjectChanged,
             .roomInviteReceived, .roomMessageReceived,
             .roomDestroyed, .mucSelfPingFailed,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .blockListLoaded, .contactBlocked, .contactUnblocked:
            break
        }
    }

    private func handleMUCSelfPingFailed(room: BareJID, reason: MUCSelfPingFailure, accountID: UUID) async {
        switch reason {
        case .notJoined:
            log.warning("MUC self-ping: not joined \(room), triggering rejoin")
            let conversations = await (try? store.fetchConversations(for: accountID)) ?? []
            let conversation = conversations.first { $0.jid == room && $0.type == .groupchat }
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
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged,
             .roomSubjectChanged, .roomInviteReceived, .roomMessageReceived,
             .roomDestroyed, .mucSelfPingFailed,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .blockListLoaded, .contactBlocked, .contactUnblocked:
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

    private func handleRoomJoined(room: BareJID, occupancy: RoomOccupancy, isNewlyCreated: Bool, accountID: UUID) async {
        _ = try? await findOrCreateGroupConversation(for: room, nickname: occupancy.nickname, accountID: accountID)
        let key = room.description
        roomParticipants[key] = occupancy.occupants.map { mapOccupant($0) }
        if isNewlyCreated {
            newlyCreatedRoomJIDs.insert(key)
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
            password: invite.password
        )
        // Deduplicate by room+from
        guard !pendingInvites.contains(where: { $0.roomJIDString == pending.roomJIDString && $0.fromJIDString == pending.fromJIDString }) else {
            return
        }
        pendingInvites.append(pending)
    }

    private func handleRoomMessageReceived(_ xmppMessage: XMPPMessage, accountID: UUID) async {
        guard let body = xmppMessage.body,
              let from = xmppMessage.from else { return }

        let roomJID = from.bareJID

        let senderNickname: String? = if case let .full(fullJID) = from {
            fullJID.resourcePart
        } else {
            nil
        }

        // Skip own messages (the server echoes them back)
        if let senderNickname,
           let client = accountService?.client(for: accountID),
           let mucModule = await client.module(ofType: MUCModule.self) {
            let ownNickname = mucModule.nickname(in: roomJID)
            if senderNickname == ownNickname {
                return
            }
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

        let fromLabel = senderNickname ?? roomJID.description
        let message = ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            stanzaID: xmppMessage.id,
            fromJID: fromLabel,
            body: filtered.body,
            htmlBody: filtered.htmlBody,
            timestamp: Date(),
            isOutgoing: false,
            isRead: false,
            isDelivered: false,
            isEdited: false,
            type: "groupchat"
        )
        try? await persistMessage(message, in: conversation, incrementUnread: true, accountID: accountID)

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
            replyToID: replyToID
        )
        let isActiveConversation = conversation.id == activeConversationID
        try? await persistMessage(message, in: conversation, incrementUnread: !isActiveConversation, accountID: accountID)

        if isActiveConversation {
            try? await store.markMessagesRead(in: conversation.id)
            if conversation.type == .chat, let stanzaID = message.stanzaID {
                try? await sendDisplayedMarker(to: conversation.jid, messageStanzaID: stanzaID, accountID: accountID)
            }
        }

        onIncomingMessage?(message, conversation)
    }

    private func handleCarbon(_ forwarded: ForwardedMessage, accountID: UUID, isOutgoing: Bool) async {
        let jid = isOutgoing ? forwarded.message.to?.bareJID : forwarded.message.from?.bareJID
        guard forwarded.message.messageType != .groupchat,
              let body = forwarded.message.body,
              let jid else { return }

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
            type: "chat"
        )
        try? await persistMessage(message, in: conversation, accountID: accountID)
    }

    private func parseISO8601Timestamp(_ stamp: String?) -> Date {
        guard let stamp else { return Date() }
        let isoStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let basicStyle = Date.ISO8601FormatStyle()
        return (try? isoStyle.parse(stamp)) ?? (try? basicStyle.parse(stamp)) ?? Date()
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

        let (archived, fin) = try await mamModule.queryMessages(with: jid, end: endISO, max: limit)
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

                let (archived, _) = try await mamModule.queryMessages(
                    with: conversation.jid, start: startISO, max: 50
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
            createdAt: Date()
        )
        try await store.upsertConversation(conversation)
        return conversation
    }
}
