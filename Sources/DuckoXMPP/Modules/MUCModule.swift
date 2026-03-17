import os

private let log = Logger(subsystem: "com.ducko.xmpp", category: "muc")

/// XEP-0424 fallback body for clients that don't support message retraction.
private let retractionFallbackBody = "This person attempted to retract a previous message, but it's unsupported by your client."

/// Implements XEP-0045 Multi-User Chat — room join/leave, occupant tracking, group messaging, and invitations.
public final class MUCModule: XMPPModule, Sendable {
    // MARK: - State

    /// Self-ping interval for detecting silent MUC disconnections (XEP-0410).
    private static let selfPingInterval: Duration = .seconds(900)

    private struct RoomState {
        var nickname: String
        var password: String?
        var history: RoomHistoryFetch = .initial
        var occupants: [String: RoomOccupant] = [:]
        var subject: String?
        var lastActivity: ContinuousClock.Instant = .now
        var selfPingTask: Task<Void, Never>?
    }

    private struct State {
        var context: ModuleContext?
        var rooms: [BareJID: RoomState] = [:]
        var pendingNickChanges: [BareJID: [String: RoomOccupant]] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    public var features: [String] {
        [XMPPNamespaces.muc, XMPPNamespaces.mucDirectInvite, XMPPNamespaces.messageCorrect]
    }

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Lifecycle

    public func handleConnect() async throws {
        let (rooms, optionalContext) = state.withLock { ($0.rooms, $0.context) }
        guard let context = optionalContext else { return }

        // Auto-rejoin previously joined rooms
        for (room, roomState) in rooms {
            let presence = buildJoinPresence(room: room, nickname: roomState.nickname, password: roomState.password, history: roomState.history, context: context)
            do {
                try await context.sendStanza(presence)
            } catch {
                log.warning("Failed to rejoin room \(room): \(error)")
            }
        }
    }

    public func handleDisconnect() async {
        let tasks = state.withLock { state -> [Task<Void, Never>] in
            var tasks: [Task<Void, Never>] = []
            for key in state.rooms.keys {
                state.rooms[key]?.occupants.removeAll()
                if let task = state.rooms[key]?.selfPingTask {
                    tasks.append(task)
                    state.rooms[key]?.selfPingTask = nil
                }
            }
            state.pendingNickChanges.removeAll()
            return tasks
        }
        for task in tasks {
            task.cancel()
        }
    }

    // MARK: - Presence Handling

    /// Groups parsed presence info passed between presence-handling methods.
    private struct PresenceInfo {
        let roomJID: BareJID
        let nickname: String
        let occupant: RoomOccupant
        let item: XMLElement?
        let mucUser: XMLElement?
        let statusCodes: Set<Int>
        var isSelfPresence: Bool {
            statusCodes.contains(110)
        }
    }

    public func handlePresence(_ presence: XMPPPresence) throws {
        guard let from = presence.from,
              case let .full(fullJID) = from else { return }

        let roomJID = fullJID.bareJID
        let nickname = fullJID.resourcePart

        // Only handle presence for rooms we're tracking
        let (isTracked, context) = state.withLock { ($0.rooms[roomJID] != nil, $0.context) }
        guard isTracked else { return }

        let mucUser = presence.element.child(named: "x", namespace: XMPPNamespaces.mucUser)
        let item = mucUser?.child(named: "item")
        let occupant: RoomOccupant = if let item, let parsed = RoomOccupant.parse(item, nickname: nickname) {
            parsed
        } else {
            RoomOccupant(nickname: nickname, affiliation: .none, role: .participant)
        }

        let info = PresenceInfo(
            roomJID: roomJID, nickname: nickname, occupant: occupant,
            item: item, mucUser: mucUser, statusCodes: parseStatusCodes(mucUser)
        )

        if presence.presenceType == .unavailable {
            handleUnavailablePresence(info, context: context)
        } else {
            handleAvailablePresence(info, context: context)
        }
    }

    private func handleUnavailablePresence(_ info: PresenceInfo, context: ModuleContext?) {
        // Nick change (status 303): store old occupant under new nick, don't emit leave
        if info.statusCodes.contains(303), let newNick = info.item?.attribute("nick") {
            state.withLock { state in
                var pending = state.pendingNickChanges[info.roomJID] ?? [:]
                pending[newNick] = info.occupant
                state.pendingNickChanges[info.roomJID] = pending
            }
            return
        }

        // Room destruction: check for <destroy> in muc#user
        if info.isSelfPresence, let destroy = info.mucUser?.child(named: "destroy") {
            let reason = destroy.child(named: "reason")?.textContent
            let alternateVenue = destroy.attribute("jid").flatMap { BareJID.parse($0) }
            let pingTask = state.withLock { state -> Task<Void, Never>? in
                let task = state.rooms[info.roomJID]?.selfPingTask
                state.rooms.removeValue(forKey: info.roomJID)
                state.pendingNickChanges.removeValue(forKey: info.roomJID)
                return task
            }
            pingTask?.cancel()
            log.info("Room \(info.roomJID) was destroyed")
            context?.emitEvent(.roomDestroyed(room: info.roomJID, reason: reason, alternateVenue: alternateVenue))
            return
        }

        // Parse leave reason from MUC status codes
        let itemReason = info.item?.child(named: "reason")?.textContent
        let leaveReason: OccupantLeaveReason? = if info.statusCodes.contains(301) {
            .banned(reason: itemReason)
        } else if info.statusCodes.contains(307) {
            .kicked(reason: itemReason)
        } else if info.statusCodes.contains(321) {
            .affiliationChanged(reason: itemReason)
        } else if info.statusCodes.contains(332) {
            .serviceShutdown
        } else {
            nil
        }

        handleOccupantLeft(roomJID: info.roomJID, nickname: info.nickname, occupant: info.occupant, leaveReason: leaveReason, context: context)
    }

    private func handleAvailablePresence(_ info: PresenceInfo, context: ModuleContext?) {
        // Check if this is the second half of a nick change
        let pendingOccupant = state.withLock { state -> RoomOccupant? in
            state.pendingNickChanges[info.roomJID]?.removeValue(forKey: info.nickname)
        }

        if let pendingOccupant {
            let oldNickname = pendingOccupant.nickname
            state.withLock { state in
                state.rooms[info.roomJID]?.occupants.removeValue(forKey: oldNickname)
                state.rooms[info.roomJID]?.occupants[info.nickname] = info.occupant
                if info.isSelfPresence {
                    state.rooms[info.roomJID]?.nickname = info.nickname
                }
            }
            log.info("Occupant \(oldNickname) changed nick to \(info.nickname) in \(info.roomJID)")
            context?.emitEvent(.roomOccupantNickChanged(room: info.roomJID, oldNickname: oldNickname, occupant: info.occupant))
        } else if info.isSelfPresence {
            handleSelfJoined(roomJID: info.roomJID, nickname: info.nickname, occupant: info.occupant, statusCodes: info.statusCodes, context: context)
        } else {
            handleOccupantJoined(roomJID: info.roomJID, nickname: info.nickname, occupant: info.occupant, context: context)
        }
    }

    private func handleSelfJoined(
        roomJID: BareJID,
        nickname: String,
        occupant: RoomOccupant,
        statusCodes: Set<Int>,
        context: ModuleContext?
    ) {
        let flags: Set<RoomFlag> = {
            var result = Set<RoomFlag>()
            if statusCodes.contains(100) { result.insert(.nonAnonymous) }
            if statusCodes.contains(170) { result.insert(.logged) }
            return result
        }()

        let occupancy = state.withLock { state -> RoomOccupancy in
            state.rooms[roomJID]?.occupants[nickname] = occupant
            state.rooms[roomJID]?.lastActivity = .now
            guard let room = state.rooms[roomJID] else {
                return RoomOccupancy(nickname: nickname, occupants: [occupant], subject: nil, flags: flags)
            }
            return RoomOccupancy(
                nickname: nickname,
                occupants: Array(room.occupants.values),
                subject: room.subject,
                flags: flags
            )
        }
        let isNewlyCreated = statusCodes.contains(201)
        log.info("Joined room \(roomJID) as \(nickname)\(isNewlyCreated ? " [new room]" : "")")
        context?.emitEvent(.roomJoined(room: roomJID, occupancy: occupancy, isNewlyCreated: isNewlyCreated))
        startSelfPing(for: roomJID)
    }

    private func handleOccupantJoined(roomJID: BareJID, nickname: String, occupant: RoomOccupant, context: ModuleContext?) {
        state.withLock {
            $0.rooms[roomJID]?.occupants[nickname] = occupant
            $0.rooms[roomJID]?.lastActivity = .now
        }
        log.info("Occupant \(nickname) joined \(roomJID)")
        context?.emitEvent(.roomOccupantJoined(room: roomJID, occupant: occupant))
    }

    private func handleOccupantLeft(
        roomJID: BareJID,
        nickname: String,
        occupant: RoomOccupant,
        leaveReason: OccupantLeaveReason? = nil,
        context: ModuleContext?
    ) {
        let (isSelf, pingTask) = state.withLock { state -> (Bool, Task<Void, Never>?) in
            state.rooms[roomJID]?.occupants.removeValue(forKey: nickname)
            let selfLeft = state.rooms[roomJID]?.nickname == nickname
            var task: Task<Void, Never>?
            if selfLeft {
                task = state.rooms[roomJID]?.selfPingTask
                state.rooms.removeValue(forKey: roomJID)
            }
            return (selfLeft, task)
        }
        pingTask?.cancel()

        if isSelf {
            log.info("Left room \(roomJID)")
        } else {
            log.info("Occupant \(nickname) left \(roomJID)")
        }

        context?.emitEvent(.roomOccupantLeft(room: roomJID, occupant: occupant, reason: leaveReason))
    }

    // MARK: - Message Handling

    public func handleMessage(_ message: XMPPMessage) throws {
        // Handle mediated invites (in normal or no-type messages)
        if let mucUser = message.element.child(named: "x", namespace: XMPPNamespaces.mucUser),
           let invite = mucUser.child(named: "invite") {
            handleMediatedInvite(message: message, invite: invite, mucUser: mucUser)
            return
        }

        // Handle direct invites (XEP-0249)
        if let conference = message.element.child(named: "x", namespace: XMPPNamespaces.mucDirectInvite) {
            handleDirectInvite(message: message, conference: conference)
            return
        }

        // Only handle groupchat messages for tracked rooms
        guard message.messageType == .groupchat,
              let from = message.from else { return }

        let roomJID = from.bareJID
        let isTracked = state.withLock { $0.rooms[roomJID] != nil }
        guard isTracked else { return }

        // Subject change
        if let subject = message.subject {
            state.withLock { $0.rooms[roomJID]?.subject = subject }
            let context = state.withLock { $0.context }
            context?.emitEvent(.roomSubjectChanged(room: roomJID, subject: subject.isEmpty ? nil : subject, setter: from))
            return
        }

        // XEP-0424/0425: Message retraction or moderation
        if let retract = message.element.child(named: "retract", namespace: XMPPNamespaces.messageRetract) {
            handleRetraction(retract: retract, from: from, roomJID: roomJID)
            return
        }

        // XEP-0308: Message correction in groupchat
        if let replace = message.element.child(named: "replace", namespace: XMPPNamespaces.messageCorrect),
           let originalID = replace.attribute("id"),
           let newBody = message.body {
            let context = state.withLock { state -> ModuleContext? in
                state.rooms[roomJID]?.lastActivity = .now
                return state.context
            }
            context?.emitEvent(.messageCorrected(originalID: originalID, newBody: newBody, from: from))
            return
        }

        // Group message
        guard message.body != nil else { return }

        let context = state.withLock { state -> ModuleContext? in
            state.rooms[roomJID]?.lastActivity = .now
            return state.context
        }
        context?.emitEvent(.roomMessageReceived(message))
    }

    private func handleMediatedInvite(message: XMPPMessage, invite: XMLElement, mucUser: XMLElement) {
        guard let roomJID = message.from?.bareJID,
              let fromString = invite.attribute("from"),
              let from = JID.parse(fromString) else { return }

        let reason = invite.child(named: "reason")?.textContent
        let password = mucUser.child(named: "password")?.textContent
        let roomInvite = RoomInvite(room: roomJID, from: from, reason: reason, password: password)

        let context = state.withLock { $0.context }
        log.info("Received mediated invite to \(roomJID) from \(from)")
        context?.emitEvent(.roomInviteReceived(roomInvite))
    }

    private func handleDirectInvite(message: XMPPMessage, conference: XMLElement) {
        guard let jidString = conference.attribute("jid"),
              let roomJID = BareJID.parse(jidString),
              let from = message.from else { return }

        let reason = conference.attribute("reason")
        let password = conference.attribute("password")
        let isContinuation = conference.attribute("continue") == "true"
        let thread = conference.attribute("thread")
        let roomInvite = RoomInvite(room: roomJID, from: from, reason: reason, password: password, isContinuation: isContinuation, thread: thread)

        let context = state.withLock { $0.context }
        log.info("Received direct invite to \(roomJID) from \(from)")
        context?.emitEvent(.roomInviteReceived(roomInvite))
    }

    private func handleRetraction(retract: XMLElement, from: JID, roomJID: BareJID) {
        let context = state.withLock { $0.context }
        if let moderated = retract.child(named: "moderated", namespace: XMPPNamespaces.messageModerate),
           let originalID = retract.attribute("id") {
            // XEP-0425: moderation messages come from bare room JID only
            guard case .bare = from else {
                log.warning("Rejected moderation from non-bare JID: \(from)")
                return
            }
            let moderator = moderated.attribute("by") ?? from.description
            let reason = retract.child(named: "reason")?.textContent
            context?.emitEvent(.messageModerated(originalID: originalID, moderator: moderator, room: roomJID, reason: reason))
        } else if let originalID = retract.attribute("id") {
            context?.emitEvent(.messageRetracted(originalID: originalID, from: from))
        }
    }

    // MARK: - Public API

    /// Joins a MUC room with the given nickname.
    public func joinRoom(_ room: BareJID, nickname: String, password: String? = nil, history: RoomHistoryFetch = .initial) async throws {
        guard let context = state.withLock({ $0.context }) else { return }

        let (existingPingTask, effectivePassword) = state.withLock { state -> (Task<Void, Never>?, String?) in
            let task = state.rooms[room]?.selfPingTask
            let pw = password ?? state.rooms[room]?.password
            state.rooms[room] = RoomState(nickname: nickname, password: pw, history: history)
            return (task, pw)
        }
        existingPingTask?.cancel()

        let presence = buildJoinPresence(room: room, nickname: nickname, password: effectivePassword, history: history, context: context)
        try await context.sendStanza(presence)
        log.info("Joining room \(room) as \(nickname)")
    }

    /// Leaves a MUC room.
    public func leaveRoom(_ room: BareJID) async throws {
        guard let context = state.withLock({ $0.context }) else { return }

        let (nickname, pingTask) = state.withLock { state -> (String?, Task<Void, Never>?) in
            let nick = state.rooms[room]?.nickname
            let task = state.rooms[room]?.selfPingTask
            state.rooms.removeValue(forKey: room)
            state.pendingNickChanges.removeValue(forKey: room)
            return (nick, task)
        }
        pingTask?.cancel()
        guard let nickname else { return }

        guard let fullJID = FullJID(bareJID: room, resourcePart: nickname) else { return }
        let presence = XMPPPresence(type: .unavailable, to: .full(fullJID))
        try await context.sendStanza(presence)
        log.info("Leaving room \(room)")
    }

    /// Sends a groupchat message to a room.
    public func sendMessage(
        to room: BareJID, body: String, id: String? = nil,
        markable: Bool = false, additionalElements: [XMLElement] = []
    ) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        let stanzaID = id ?? context.generateID()
        var message = XMPPMessage(type: .groupchat, to: .bare(room), id: stanzaID)
        message.body = body
        if markable {
            let markableElement = XMLElement(name: "markable", namespace: XMPPNamespaces.chatMarkers)
            message.element.addChild(markableElement)
        }
        for element in additionalElements {
            message.element.addChild(element)
        }
        try await context.sendStanza(message)
    }

    /// Sends a message correction (XEP-0308) for a previously sent groupchat message.
    public func sendCorrection(to room: BareJID, body: String, replacingID: String) async throws {
        let replace = XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": replacingID])
        try await sendMessage(to: room, body: body, additionalElements: [replace])
    }

    /// Sends a message retraction (XEP-0424) for a previously sent groupchat message.
    public func sendRetraction(to room: BareJID, originalID: String) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var message = XMPPMessage(type: .groupchat, to: .bare(room), id: context.generateID())
        let retract = XMLElement(
            name: "retract",
            namespace: XMPPNamespaces.messageRetract,
            attributes: ["id": originalID]
        )
        message.element.addChild(retract)
        let fallback = XMLElement(name: "fallback", namespace: XMPPNamespaces.fallbackIndication, attributes: ["for": XMPPNamespaces.messageRetract])
        message.element.addChild(fallback)
        message.body = retractionFallbackBody
        let store = XMLElement(name: "store", namespace: XMPPNamespaces.processingHints)
        message.element.addChild(store)
        try await context.sendStanza(message)
    }

    // periphery:ignore - specced feature (XEP-0425), not yet wired to UI
    /// Sends a moderation request (XEP-0425) to retract a message by stanza-id.
    public func moderateMessage(room: BareJID, stanzaID: String, reason: String? = nil) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var iq = XMPPIQ(type: .set, to: .bare(room), id: context.generateID())
        var moderate = XMLElement(
            name: "moderate",
            namespace: XMPPNamespaces.messageModerate,
            attributes: ["id": stanzaID]
        )
        let retract = XMLElement(name: "retract", namespace: XMPPNamespaces.messageRetract)
        moderate.addChild(retract)
        if let reason {
            var reasonElement = XMLElement(name: "reason")
            reasonElement.addText(reason)
            moderate.addChild(reasonElement)
        }
        iq.element.addChild(moderate)
        _ = try await context.sendIQ(iq)
    }

    /// Sets the room subject.
    public func setSubject(in room: BareJID, subject: String) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var message = XMPPMessage(type: .groupchat, to: .bare(room))
        message.subject = subject
        try await context.sendStanza(message)
    }

    /// Sends a direct invitation (XEP-0249) to a user.
    public func inviteUser(
        _ jid: BareJID,
        to room: BareJID,
        reason: String? = nil,
        password: String? = nil,
        isContinuation: Bool = false,
        thread: String? = nil
    ) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var message = XMPPMessage(type: .normal, to: .bare(jid))
        var conference = XMLElement(name: "x", namespace: XMPPNamespaces.mucDirectInvite, attributes: ["jid": room.description])
        if let reason { conference.setAttribute("reason", value: reason) }
        if let password { conference.setAttribute("password", value: password) }
        if isContinuation { conference.setAttribute("continue", value: "true") }
        if let thread { conference.setAttribute("thread", value: thread) }
        message.element.addChild(conference)
        try await context.sendStanza(message)
    }

    /// Declines a MUC room invitation (XEP-0045 §7.8).
    public func declineInvite(room: BareJID, inviter: JID, reason: String? = nil) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var decline = XMLElement(name: "decline", attributes: ["to": inviter.description])
        appendReason(reason, to: &decline)
        var mucUser = XMLElement(name: "x", namespace: XMPPNamespaces.mucUser)
        mucUser.addChild(decline)
        var message = XMPPMessage(type: .normal, to: .bare(room))
        message.element.addChild(mucUser)
        try await context.sendStanza(message)
    }

    /// Kicks an occupant from the room by nickname.
    public func kickOccupant(nickname: String, from room: BareJID, reason: String? = nil) async throws {
        try await setRole(nickname: nickname, in: room, to: .none, reason: reason)
    }

    /// Bans a user from the room by JID.
    public func banUser(jid: BareJID, from room: BareJID, reason: String? = nil) async throws {
        try await setAffiliation(jid: jid, in: room, to: .outcast, reason: reason)
    }

    /// Discovers rooms on a MUC service using disco#items.
    public func discoverRooms(on service: String) async throws -> [(jid: BareJID, name: String?)] {
        guard let context = state.withLock({ $0.context }) else { return [] }
        guard let serviceJID = BareJID.parse(service) else { return [] }
        var iq = XMPPIQ(type: .get, to: .bare(serviceJID), id: context.generateID())
        let query = XMLElement(name: "query", namespace: XMPPNamespaces.discoItems)
        iq.element.addChild(query)

        guard let result = try await context.sendIQ(iq) else { return [] }

        return result.children(named: "item").compactMap { item in
            guard let jidString = item.attribute("jid"),
                  let jid = BareJID.parse(jidString) else { return nil }
            return (jid: jid, name: item.attribute("name"))
        }
    }

    /// Returns the nickname used in a given room, if any.
    public func nickname(in room: BareJID) -> String? {
        state.withLock { $0.rooms[room]?.nickname }
    }

    /// Changes the user's nickname in a room.
    public func changeNickname(in room: BareJID, to newNickname: String) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        guard let fullJID = FullJID(bareJID: room, resourcePart: newNickname) else { return }
        let presence = XMPPPresence(to: .full(fullJID), id: context.generateID())
        try await context.sendStanza(presence)
    }

    // MARK: - Room Configuration (muc#owner)

    /// Retrieves the room configuration form.
    public func getRoomConfig(_ room: BareJID) async throws -> [DataFormField] {
        guard let context = state.withLock({ $0.context }) else { return [] }
        var iq = XMPPIQ(type: .get, to: .bare(room), id: context.generateID())
        let query = XMLElement(name: "query", namespace: XMPPNamespaces.mucOwner)
        iq.element.addChild(query)

        guard let result = try await context.sendIQ(iq) else { return [] }
        guard let form = result.child(named: "x", namespace: XMPPNamespaces.dataForms) else { return [] }
        return parseDataForm(form)
    }

    /// Submits a room configuration form.
    public func submitRoomConfig(_ room: BareJID, fields: [DataFormField]) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var iq = XMPPIQ(type: .set, to: .bare(room), id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.mucOwner)
        let form = buildSubmitForm(fields)
        query.addChild(form)
        iq.element.addChild(query)
        _ = try await context.sendIQ(iq)
    }

    /// Accepts the default room configuration (instant room).
    public func acceptDefaultConfig(_ room: BareJID) async throws {
        try await submitRoomConfig(room, fields: [])
    }

    // MARK: - Voice Management

    /// Sets the role of an occupant by nickname.
    public func setRole(nickname: String, in room: BareJID, to role: MUCRole, reason: String? = nil) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var iq = XMPPIQ(type: .set, to: .bare(room), id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.mucAdmin)
        var item = XMLElement(name: "item", attributes: ["nick": nickname, "role": role.rawValue])
        appendReason(reason, to: &item)
        query.addChild(item)
        iq.element.addChild(query)
        _ = try await context.sendIQ(iq)
    }

    /// Grants voice (participant role) to a visitor.
    public func grantVoice(nickname: String, in room: BareJID) async throws {
        try await setRole(nickname: nickname, in: room, to: .participant)
    }

    /// Revokes voice (visitor role) from a participant.
    public func revokeVoice(nickname: String, in room: BareJID) async throws {
        try await setRole(nickname: nickname, in: room, to: .visitor)
    }

    // MARK: - Affiliation Management

    /// Retrieves the affiliation list for a given affiliation.
    public func getAffiliationList(_ affiliation: MUCAffiliation, in room: BareJID) async throws -> [MUCAffiliationItem] {
        guard let context = state.withLock({ $0.context }) else { return [] }
        var iq = XMPPIQ(type: .get, to: .bare(room), id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.mucAdmin)
        let item = XMLElement(name: "item", attributes: ["affiliation": affiliation.rawValue])
        query.addChild(item)
        iq.element.addChild(query)

        guard let result = try await context.sendIQ(iq) else { return [] }
        return result.children(named: "item").compactMap { MUCAffiliationItem.parse($0) }
    }

    /// Sets the affiliation of a user by JID.
    public func setAffiliation(jid: BareJID, in room: BareJID, to affiliation: MUCAffiliation, reason: String? = nil) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var iq = XMPPIQ(type: .set, to: .bare(room), id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.mucAdmin)
        var item = XMLElement(name: "item", attributes: ["jid": jid.description, "affiliation": affiliation.rawValue])
        appendReason(reason, to: &item)
        query.addChild(item)
        iq.element.addChild(query)
        _ = try await context.sendIQ(iq)
    }

    // MARK: - Room Destruction

    /// Destroys a room (owner-only).
    public func destroyRoom(_ room: BareJID, reason: String? = nil, alternateVenue: BareJID? = nil) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var iq = XMPPIQ(type: .set, to: .bare(room), id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.mucOwner)
        var destroy = XMLElement(name: "destroy")
        if let alternateVenue {
            destroy.setAttribute("jid", value: alternateVenue.description)
        }
        appendReason(reason, to: &destroy)
        query.addChild(destroy)
        iq.element.addChild(query)
        _ = try await context.sendIQ(iq)
    }

    // MARK: - Self-Ping (XEP-0410)

    private func startSelfPing(for room: BareJID) {
        // Cancel any existing task
        let existing = state.withLock { $0.rooms[room]?.selfPingTask }
        existing?.cancel()

        let task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.selfPingInterval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                await performSelfPing(for: room)
            }
        }
        state.withLock { $0.rooms[room]?.selfPingTask = task }
    }

    private func performSelfPing(for room: BareJID) async {
        let (nickname, context, lastActivity) = state.withLock { state in
            (state.rooms[room]?.nickname, state.context, state.rooms[room]?.lastActivity)
        }
        guard let nickname, let context, let lastActivity else { return }

        // Skip ping if recent activity
        let elapsed = ContinuousClock.now - lastActivity
        if elapsed < Self.selfPingInterval {
            return
        }

        guard let fullJID = FullJID(bareJID: room, resourcePart: nickname) else { return }

        var pingIQ = XMPPIQ(type: .get, to: .full(fullJID), id: context.generateID())
        let pingChild = XMLElement(name: "ping", namespace: XMPPNamespaces.ping)
        pingIQ.element.addChild(pingChild)

        do {
            _ = try await context.sendIQ(pingIQ)
            // Success — still joined
            state.withLock { $0.rooms[room]?.lastActivity = .now }
        } catch let error as XMPPStanzaError {
            handleSelfPingError(error, room: room, nickname: nickname, context: context)
        } catch {
            // Timeout or network error — retry on next interval
            log.debug("Self-ping timeout for \(room): \(error)")
        }
    }

    private func handleSelfPingError(_ error: XMPPStanzaError, room: BareJID, nickname: String, context: ModuleContext) {
        switch error.condition {
        case .serviceUnavailable, .featureNotImplemented:
            // Server doesn't support ping but we're still joined
            state.withLock { $0.rooms[room]?.lastActivity = .now }
        case .itemNotFound:
            // Nickname changed or room configuration issue
            log.warning("Self-ping item-not-found for \(room)")
            context.emitEvent(.mucSelfPingFailed(room: room, reason: .nickChanged(nickname)))
        case .notAcceptable:
            // Not joined — trigger rejoin
            log.warning("Self-ping not-acceptable for \(room) — not joined")
            context.emitEvent(.mucSelfPingFailed(room: room, reason: .notJoined))
        case .remoteServerNotFound, .remoteServerTimeout:
            // Transient — retry on next interval
            log.debug("Self-ping remote error for \(room): \(error.condition.rawValue)")
        case .badRequest, .conflict, .forbidden, .gone, .internalServerError,
             .jidMalformed, .notAllowed, .notAuthorized, .policyViolation,
             .recipientUnavailable, .redirect, .registrationRequired,
             .resourceConstraint, .subscriptionRequired, .undefinedCondition,
             .unexpectedRequest:
            log.debug("Self-ping error for \(room): \(error.condition.rawValue)")
        }
    }

    // MARK: - Private Helpers

    private func buildJoinPresence(
        room: BareJID,
        nickname: String,
        password: String?,
        history: RoomHistoryFetch = .initial,
        context: ModuleContext
    ) -> XMPPPresence {
        guard let fullJID = FullJID(bareJID: room, resourcePart: nickname) else {
            // Fallback: this shouldn't happen with valid nickname
            return XMPPPresence(to: .bare(room))
        }
        var presence = XMPPPresence(to: .full(fullJID), id: context.generateID())
        var mucElement = XMLElement(name: "x", namespace: XMPPNamespaces.muc)
        if let password {
            var passwordElement = XMLElement(name: "password")
            passwordElement.addText(password)
            mucElement.addChild(passwordElement)
        }
        switch history {
        case .initial:
            break
        case let .since(timestamp):
            let historyElement = XMLElement(name: "history", attributes: ["since": timestamp])
            mucElement.addChild(historyElement)
        case .skip:
            let historyElement = XMLElement(name: "history", attributes: ["maxchars": "0", "maxstanzas": "0"])
            mucElement.addChild(historyElement)
        }
        presence.element.addChild(mucElement)
        return presence
    }

    private func appendReason(_ reason: String?, to item: inout XMLElement) {
        guard let reason else { return }
        var reasonElement = XMLElement(name: "reason")
        reasonElement.addText(reason)
        item.addChild(reasonElement)
    }

    private func parseStatusCodes(_ mucUser: XMLElement?) -> Set<Int> {
        guard let mucUser else { return [] }
        var codes = Set<Int>()
        for status in mucUser.children(named: "status") {
            if let codeStr = status.attribute("code"), let code = Int(codeStr) {
                codes.insert(code)
            }
        }
        return codes
    }
}
