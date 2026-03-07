import os

private let log = Logger(subsystem: "com.ducko.xmpp", category: "muc")

/// Implements XEP-0045 Multi-User Chat — room join/leave, occupant tracking, group messaging, and invitations.
public final class MUCModule: XMPPModule, Sendable {
    // MARK: - State

    private struct RoomState {
        var nickname: String
        var password: String?
        var occupants: [String: RoomOccupant] = [:]
        var subject: String?
        var joined: Bool = false
    }

    private struct State {
        var context: ModuleContext?
        var rooms: [BareJID: RoomState] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    public var features: [String] {
        [XMPPNamespaces.muc]
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
            let presence = buildJoinPresence(room: room, nickname: roomState.nickname, password: roomState.password, context: context)
            do {
                try await context.sendStanza(presence)
            } catch {
                log.warning("Failed to rejoin room \(room): \(error)")
            }
        }
    }

    public func handleDisconnect() async {
        state.withLock { state in
            for key in state.rooms.keys {
                state.rooms[key]?.joined = false
                state.rooms[key]?.occupants.removeAll()
            }
        }
    }

    // MARK: - Presence Handling

    public func handlePresence(_ presence: XMPPPresence) throws {
        guard let from = presence.from,
              case let .full(fullJID) = from else { return }

        let roomJID = fullJID.bareJID
        let nickname = fullJID.resourcePart

        // Only handle presence for rooms we're tracking
        let (isTracked, context) = state.withLock { ($0.rooms[roomJID] != nil, $0.context) }
        guard isTracked else { return }

        let mucUser = presence.element.child(named: "x", namespace: XMPPNamespaces.mucUser)

        // Parse occupant from muc#user item
        let item = mucUser?.child(named: "item")
        let occupant: RoomOccupant = if let item, let parsed = RoomOccupant.parse(item, nickname: nickname) {
            parsed
        } else {
            // Minimal occupant if no muc#user element
            RoomOccupant(nickname: nickname, affiliation: .none, role: .participant)
        }

        // Check for status codes
        let statusCodes = parseStatusCodes(mucUser)
        let isSelfPresence = statusCodes.contains(110)

        if presence.presenceType == .unavailable {
            handleOccupantLeft(roomJID: roomJID, nickname: nickname, occupant: occupant, context: context)
        } else if isSelfPresence {
            handleSelfJoined(roomJID: roomJID, nickname: nickname, occupant: occupant, context: context)
        } else {
            handleOccupantJoined(roomJID: roomJID, nickname: nickname, occupant: occupant, context: context)
        }
    }

    private func handleSelfJoined(roomJID: BareJID, nickname: String, occupant: RoomOccupant, context: ModuleContext?) {
        let occupancy = state.withLock { state -> RoomOccupancy in
            state.rooms[roomJID]?.joined = true
            state.rooms[roomJID]?.occupants[nickname] = occupant
            guard let room = state.rooms[roomJID] else {
                return RoomOccupancy(room: roomJID, nickname: nickname, occupants: [occupant], subject: nil)
            }
            return RoomOccupancy(
                room: roomJID,
                nickname: nickname,
                occupants: Array(room.occupants.values),
                subject: room.subject
            )
        }
        log.info("Joined room \(roomJID) as \(nickname)")
        context?.emitEvent(.roomJoined(room: roomJID, occupancy: occupancy))
    }

    private func handleOccupantJoined(roomJID: BareJID, nickname: String, occupant: RoomOccupant, context: ModuleContext?) {
        state.withLock { $0.rooms[roomJID]?.occupants[nickname] = occupant }
        log.info("Occupant \(nickname) joined \(roomJID)")
        context?.emitEvent(.roomOccupantJoined(room: roomJID, occupant: occupant))
    }

    private func handleOccupantLeft(
        roomJID: BareJID,
        nickname: String,
        occupant: RoomOccupant,
        context: ModuleContext?
    ) {
        let isSelf = state.withLock { state -> Bool in
            state.rooms[roomJID]?.occupants.removeValue(forKey: nickname)
            let selfLeft = state.rooms[roomJID]?.nickname == nickname
            if selfLeft {
                state.rooms.removeValue(forKey: roomJID)
            }
            return selfLeft
        }

        if isSelf {
            log.info("Left room \(roomJID)")
        } else {
            log.info("Occupant \(nickname) left \(roomJID)")
        }

        context?.emitEvent(.roomOccupantLeft(room: roomJID, occupant: occupant))
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

        // Group message
        guard message.body != nil else { return }

        let context = state.withLock { $0.context }
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
        let roomInvite = RoomInvite(room: roomJID, from: from, reason: reason, password: password)

        let context = state.withLock { $0.context }
        log.info("Received direct invite to \(roomJID) from \(from)")
        context?.emitEvent(.roomInviteReceived(roomInvite))
    }

    // MARK: - Public API

    /// Joins a MUC room with the given nickname.
    public func joinRoom(_ room: BareJID, nickname: String, password: String? = nil) async throws {
        guard let context = state.withLock({ $0.context }) else { return }

        state.withLock { state in
            state.rooms[room] = RoomState(nickname: nickname, password: password)
        }

        let presence = buildJoinPresence(room: room, nickname: nickname, password: password, context: context)
        try await context.sendStanza(presence)
        log.info("Joining room \(room) as \(nickname)")
    }

    /// Leaves a MUC room.
    public func leaveRoom(_ room: BareJID) async throws {
        guard let context = state.withLock({ $0.context }) else { return }

        let nickname = state.withLock { state -> String? in
            let nick = state.rooms[room]?.nickname
            state.rooms.removeValue(forKey: room)
            return nick
        }
        guard let nickname else { return }

        guard let fullJID = FullJID(bareJID: room, resourcePart: nickname) else { return }
        let presence = XMPPPresence(type: .unavailable, to: .full(fullJID))
        try await context.sendStanza(presence)
        log.info("Leaving room \(room)")
    }

    /// Sends a groupchat message to a room.
    public func sendMessage(to room: BareJID, body: String, id: String? = nil) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        let stanzaID = id ?? context.generateID()
        var message = XMPPMessage(type: .groupchat, to: .bare(room), id: stanzaID)
        message.body = body
        try await context.sendStanza(message)
    }

    /// Sets the room subject.
    public func setSubject(in room: BareJID, subject: String) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var message = XMPPMessage(type: .groupchat, to: .bare(room))
        message.subject = subject
        try await context.sendStanza(message)
    }

    /// Sends a direct invitation (XEP-0249) to a user.
    public func inviteUser(_ jid: BareJID, to room: BareJID, reason: String? = nil) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var message = XMPPMessage(type: .normal, to: .bare(jid))
        var conference = XMLElement(name: "x", namespace: XMPPNamespaces.mucDirectInvite, attributes: ["jid": room.description])
        if let reason { conference.setAttribute("reason", value: reason) }
        message.element.addChild(conference)
        try await context.sendStanza(message)
    }

    /// Kicks an occupant from the room by nickname.
    public func kickOccupant(nickname: String, from room: BareJID, reason: String? = nil) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var iq = XMPPIQ(type: .set, to: .bare(room), id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.mucAdmin)
        var item = XMLElement(name: "item", attributes: ["nick": nickname, "role": "none"])
        appendReason(reason, to: &item)
        query.addChild(item)
        iq.element.addChild(query)
        _ = try await context.sendIQ(iq)
    }

    /// Bans a user from the room by JID.
    public func banUser(jid: BareJID, from room: BareJID, reason: String? = nil) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var iq = XMPPIQ(type: .set, to: .bare(room), id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.mucAdmin)
        var item = XMLElement(name: "item", attributes: ["jid": jid.description, "affiliation": "outcast"])
        appendReason(reason, to: &item)
        query.addChild(item)
        iq.element.addChild(query)
        _ = try await context.sendIQ(iq)
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

    /// Returns a snapshot of current occupants in a room.
    public func occupants(in room: BareJID) -> [RoomOccupant] {
        state.withLock { state in
            guard let room = state.rooms[room] else { return [] }
            return Array(room.occupants.values)
        }
    }

    /// Returns the list of currently joined rooms.
    public func joinedRooms() -> [BareJID] {
        state.withLock { state in
            state.rooms.filter(\.value.joined).map(\.key)
        }
    }

    /// Returns the nickname used in a given room, if any.
    public func nickname(in room: BareJID) -> String? {
        state.withLock { $0.rooms[room]?.nickname }
    }

    // MARK: - Private Helpers

    private func buildJoinPresence(room: BareJID, nickname: String, password: String?, context: ModuleContext) -> XMPPPresence {
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
