import DuckoCore
import DuckoXMPP
import Foundation

struct PlainFormatter: CLIFormatter {
    func formatMessage(_ message: ChatMessage) -> String {
        let timestamp = iso8601(message.timestamp)
        let direction = message.isOutgoing ? "->" : "<-"
        var line = "[\(timestamp)] \(direction) \(message.fromJID): \(message.body)"
        if message.isEdited {
            line += " [edited]"
        }
        if message.isOutgoing, message.isDelivered {
            line += " [delivered]"
        }
        if let errorText = message.errorText {
            line += " [error: \(errorText)]"
        }
        return line
    }

    func formatContact(_ contact: Contact) -> String {
        let name = contact.name ?? contact.jid.description
        return "\(name) (\(contact.jid)) [\(contact.subscription.rawValue)]"
    }

    func formatAccount(_ account: Account) -> String {
        "\(account.jid) (\(account.id))"
    }

    func formatContactWithPresence(_ contact: Contact, presence: PresenceService.PresenceStatus?) -> String {
        let indicator = switch presence {
        case .available:
            "[+]"
        case .away, .xa:
            "[~]"
        case .dnd:
            "[-]"
        case .offline, .none:
            "[ ]"
        }
        let displayName = contact.localAlias ?? contact.name ?? contact.jid.description
        return "\(indicator) \(displayName) (\(contact.jid)) [\(contact.subscription.rawValue)]"
    }

    func formatGroupHeader(_ group: ContactGroup) -> String {
        "--- \(group.name) (\(group.contacts.count)) ---"
    }

    func formatPresence(jid: BareJID, status: String, message: String?) -> String {
        if let message {
            return "\(jid) is \(status): \(message)"
        }
        return "\(jid) is \(status)"
    }

    func formatError(_ error: any Error) -> String {
        "error: \(error.localizedDescription)"
    }

    func formatEvent(_ event: XMPPEvent, accountID: UUID) -> String? {
        switch event {
        case let .connected(jid):
            return "connected as \(jid)"
        case let .disconnected(reason):
            return formatDisconnect(reason)
        case let .authenticationFailed(message):
            return "authentication failed: \(message)"
        case let .messageReceived(message):
            return formatIncomingMessage(message)
        case let .presenceSubscriptionRequest(from: jid):
            return "Subscription request from \(jid)"
        case let .deliveryReceiptReceived(messageID, from):
            return "delivery receipt: \(messageID) from \(from.bareJID)"
        case let .messageCorrected(_, newBody, from):
            return "message corrected by \(from.bareJID): \(newBody)"
        case let .messageError(_, from, errorText):
            return "message error from \(from.bareJID): \(errorText)"
        case .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomSubjectChanged, .roomInviteReceived, .roomMessageReceived:
            return formatMUCEvent(event)
        case .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged,
             .presenceUpdated,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .chatMarkerReceived,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed:
            return nil
        }
    }

    private func formatIncomingMessage(_ message: XMPPMessage) -> String? {
        guard let from = message.from?.bareJID, let body = message.body else { return nil }
        let timestamp = iso8601(Date())
        return "[\(timestamp)] <- \(from): \(body)"
    }

    private func formatMUCEvent(_ event: XMPPEvent) -> String? {
        switch event {
        case let .roomJoined(room, occupancy):
            var line = "Joined \(room) as \(occupancy.nickname) (\(occupancy.occupants.count) participants)"
            if let subject = occupancy.subject, !subject.isEmpty {
                line += " — topic: \(subject)"
            }
            return line
        case let .roomOccupantJoined(room, occupant):
            return "\(room): \(occupant.nickname) joined"
        case let .roomOccupantLeft(room, occupant):
            return "\(room): \(occupant.nickname) left"
        case let .roomSubjectChanged(room, subject, setter):
            let who = setter?.bareJID.description ?? "someone"
            let topic = subject ?? "(cleared)"
            return "\(room): topic changed by \(who): \(topic)"
        case let .roomInviteReceived(invite):
            var line = "Room invite: \(invite.from.bareJID) invites you to \(invite.room)"
            if let reason = invite.reason {
                line += " (\(reason))"
            }
            return line
        case let .roomMessageReceived(message):
            guard let from = message.from, let body = message.body else { return nil }
            let nickname = nicknameFromJID(from)
            let timestamp = iso8601(Date())
            return "[\(timestamp)] <- \(from.bareJID)/\(nickname): \(body)"
        case .connected, .disconnected, .authenticationFailed, .messageReceived,
             .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived,
             .chatMarkerReceived, .messageCorrected, .messageError,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed:
            return nil
        }
    }

    private func formatDisconnect(_ reason: DisconnectReason) -> String {
        switch reason {
        case .requested:
            return "disconnected"
        case let .streamError(message):
            return "disconnected: stream error: \(message)"
        case let .connectionLost(message):
            return "disconnected: connection lost: \(message)"
        }
    }

    // MARK: - Room Formatting

    func formatRoom(_ room: DiscoveredRoom) -> String {
        if let name = room.name {
            return "\(name) (\(room.jidString))"
        }
        return room.jidString
    }

    func formatRoomParticipant(_ participant: RoomParticipant) -> String {
        var line = "  \(participant.nickname)"
        if let jid = participant.jidString {
            line += " (\(jid))"
        }
        line += " [\(participant.role.rawValue)]"
        return line
    }

    func formatRoomParticipantGroupHeader(_ group: RoomParticipantGroup) -> String {
        "--- \(group.affiliation.displayName) (\(group.participants.count)) ---"
    }

    func formatRoomJoinedConfirmation(room: String, nickname: String, participantCount: Int, subject: String?) -> String {
        var line = "Joined \(room) as \(nickname) (\(participantCount) participants)"
        if let subject, !subject.isEmpty {
            line += "\nTopic: \(subject)"
        }
        return line
    }

    func formatTransferProgress(fileName: String, fileSize: Int64, progress: Double) -> String {
        let percent = Int(progress * 100)
        return "Uploading \(fileName) (\(formatByteCount(fileSize))): \(percent)%"
    }

    func formatFileMessage(fileName: String, url: String, fileSize: Int64?) -> String {
        var line = "File: \(fileName)"
        if let fileSize {
            line += " (\(formatByteCount(fileSize)))"
        }
        line += "\n  \(url)"
        return line
    }

    func formatTypingIndicator(from jid: BareJID, state: ChatState) -> String? {
        state == .composing ? "[\(jid) is typing...]" : nil
    }

    func formatConnectionState(_ state: AccountService.ConnectionState, jid: BareJID) -> String {
        switch state {
        case .disconnected:
            return "\(jid): disconnected"
        case .connecting:
            return "\(jid): connecting..."
        case let .connected(fullJID):
            return "\(jid): connected as \(fullJID)"
        case let .error(message):
            return "\(jid): error: \(message)"
        }
    }
}
