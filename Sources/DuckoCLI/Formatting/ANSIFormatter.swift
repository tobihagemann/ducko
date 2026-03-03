import DuckoCore
import DuckoXMPP
import Foundation

struct ANSIFormatter: CLIFormatter {
    // MARK: - ANSI Codes

    private enum Color {
        static let reset = "\u{001B}[0m"
        static let red = "\u{001B}[31m"
        static let green = "\u{001B}[32m"
        static let yellow = "\u{001B}[33m"
        static let cyan = "\u{001B}[36m"
        static let dim = "\u{001B}[2m"
        static let bold = "\u{001B}[1m"
    }

    // MARK: - CLIFormatter

    func formatMessage(_ message: ChatMessage) -> String {
        let timestamp = iso8601(message.timestamp)
        let direction = message.isOutgoing ? "->" : "<-"
        let color = message.isOutgoing ? Color.cyan : Color.green
        var line = "\(Color.dim)[\(timestamp)]\(Color.reset) \(color)\(direction) \(message.fromJID): \(message.body)\(Color.reset)"
        if message.isEdited {
            line += " \(Color.dim)[edited]\(Color.reset)"
        }
        if message.isOutgoing, message.isDelivered {
            line += " \(Color.green)\u{2713}\(Color.reset)"
        }
        if let errorText = message.errorText {
            line += " \(Color.red)[error: \(errorText)]\(Color.reset)"
        }
        return line
    }

    func formatContact(_ contact: Contact) -> String {
        let name = contact.name ?? contact.jid.description
        return "\(Color.bold)\(name)\(Color.reset) (\(contact.jid)) \(Color.dim)[\(contact.subscription.rawValue)]\(Color.reset)"
    }

    func formatAccount(_ account: Account) -> String {
        "\(Color.bold)\(account.jid)\(Color.reset) \(Color.dim)(\(account.id))\(Color.reset)"
    }

    func formatContactWithPresence(_ contact: Contact, presence: PresenceService.PresenceStatus?) -> String {
        let isOffline = presence == .offline || presence == nil
        let dot = isOffline ? "○" : "●"
        let color = switch presence {
        case .available:
            Color.green
        case .away, .xa:
            Color.yellow
        case .dnd:
            Color.red
        case .offline, .none:
            Color.dim
        }
        let displayName = contact.localAlias ?? contact.name ?? contact.jid.description
        return "\(color)\(dot)\(Color.reset) \(Color.bold)\(displayName)\(Color.reset) (\(contact.jid)) \(Color.dim)[\(contact.subscription.rawValue)]\(Color.reset)"
    }

    func formatGroupHeader(_ group: ContactGroup) -> String {
        "\(Color.bold)--- \(group.name) (\(group.contacts.count)) ---\(Color.reset)"
    }

    func formatPresence(jid: BareJID, status: String, message: String?) -> String {
        let color: String = switch status {
        case "available", "chat":
            Color.green
        case "dnd":
            Color.red
        default:
            Color.yellow
        }
        if let message {
            return "\(color)\(jid)\(Color.reset) is \(color)\(status)\(Color.reset): \(message)"
        }
        return "\(color)\(jid)\(Color.reset) is \(color)\(status)\(Color.reset)"
    }

    func formatError(_ error: any Error) -> String {
        "\(Color.red)error: \(error.localizedDescription)\(Color.reset)"
    }

    func formatEvent(_ event: XMPPEvent, accountID: UUID) -> String? {
        switch event {
        case let .connected(jid):
            return "\(Color.green)connected as \(jid)\(Color.reset)"
        case let .disconnected(reason):
            return formatDisconnect(reason)
        case let .authenticationFailed(message):
            return "\(Color.red)authentication failed: \(message)\(Color.reset)"
        case let .messageReceived(message):
            return formatIncomingMessage(message)
        case let .presenceSubscriptionRequest(from: jid):
            return "\(Color.yellow)⚡ Subscription request from \(jid) — use /approve or /deny\(Color.reset)"
        case let .deliveryReceiptReceived(messageID, from):
            return "\(Color.dim)\u{2713} delivery receipt: \(messageID) from \(from.bareJID)\(Color.reset)"
        case let .messageCorrected(_, newBody, from):
            return "\(Color.yellow)message corrected by \(from.bareJID): \(newBody)\(Color.reset)"
        case let .messageError(_, from, errorText):
            return "\(Color.red)message error from \(from.bareJID): \(errorText)\(Color.reset)"
        case .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomSubjectChanged, .roomInviteReceived, .roomMessageReceived:
            return formatMUCEvent(event)
        case .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged,
             .presenceUpdated,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .chatMarkerReceived:
            return nil
        }
    }

    // MARK: - Room Formatting

    func formatRoom(_ room: DiscoveredRoom) -> String {
        if let name = room.name {
            return "\(Color.bold)\(name)\(Color.reset) (\(room.jidString))"
        }
        return room.jidString
    }

    func formatRoomParticipant(_ participant: RoomParticipant) -> String {
        var line = "  \(Color.green)\(participant.nickname)\(Color.reset)"
        if let jid = participant.jidString {
            line += " (\(jid))"
        }
        line += " \(Color.dim)[\(participant.role.rawValue)]\(Color.reset)"
        return line
    }

    func formatRoomParticipantGroupHeader(_ group: RoomParticipantGroup) -> String {
        "\(Color.bold)--- \(group.affiliation.displayName) (\(group.participants.count)) ---\(Color.reset)"
    }

    func formatRoomJoinedConfirmation(room: String, nickname: String, participantCount: Int, subject: String?) -> String {
        var line = "\(Color.green)Joined \(Color.bold)\(room)\(Color.reset)\(Color.green) as \(nickname) (\(participantCount) participants)\(Color.reset)"
        if let subject, !subject.isEmpty {
            line += "\n\(Color.dim)Topic: \(subject)\(Color.reset)"
        }
        return line
    }

    private func formatIncomingMessage(_ message: XMPPMessage) -> String? {
        guard let from = message.from?.bareJID, let body = message.body else { return nil }
        let timestamp = iso8601(Date())
        return "\(Color.dim)[\(timestamp)]\(Color.reset) \(Color.green)<- \(from): \(body)\(Color.reset)"
    }

    private func formatMUCEvent(_ event: XMPPEvent) -> String? {
        switch event {
        case let .roomJoined(room, occupancy):
            var line = "\(Color.green)Joined \(Color.bold)\(room)\(Color.reset)\(Color.green) as \(occupancy.nickname) (\(occupancy.occupants.count) participants)\(Color.reset)"
            if let subject = occupancy.subject, !subject.isEmpty {
                line += " \(Color.dim)— topic: \(subject)\(Color.reset)"
            }
            return line
        case let .roomOccupantJoined(room, occupant):
            return "\(Color.yellow)\(room): \(occupant.nickname) joined\(Color.reset)"
        case let .roomOccupantLeft(room, occupant):
            return "\(Color.yellow)\(room): \(occupant.nickname) left\(Color.reset)"
        case let .roomSubjectChanged(room, subject, setter):
            let who = setter?.bareJID.description ?? "someone"
            let topic = subject ?? "(cleared)"
            return "\(Color.yellow)\(room): topic changed by \(who): \(topic)\(Color.reset)"
        case let .roomInviteReceived(invite):
            var line = "\(Color.yellow)Room invite: \(invite.from.bareJID) invites you to \(Color.bold)\(invite.room)\(Color.reset)"
            if let reason = invite.reason {
                line += "\(Color.yellow) (\(reason))\(Color.reset)"
            }
            return line
        case let .roomMessageReceived(message):
            guard let from = message.from, let body = message.body else { return nil }
            let nickname = nicknameFromJID(from)
            let timestamp = iso8601(Date())
            return "\(Color.dim)[\(timestamp)]\(Color.reset) \(Color.green)<- \(from.bareJID)/\(nickname): \(body)\(Color.reset)"
        case .connected, .disconnected, .authenticationFailed, .messageReceived,
             .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived,
             .chatMarkerReceived, .messageCorrected, .messageError:
            return nil
        }
    }

    private func formatDisconnect(_ reason: DisconnectReason) -> String {
        switch reason {
        case .requested:
            return "\(Color.yellow)disconnected\(Color.reset)"
        case let .streamError(message):
            return "\(Color.red)disconnected: stream error: \(message)\(Color.reset)"
        case let .connectionLost(message):
            return "\(Color.red)disconnected: connection lost: \(message)\(Color.reset)"
        }
    }

    func formatTransferProgress(fileName: String, fileSize: Int64, progress: Double) -> String {
        let percent = Int(progress * 100)
        let barWidth = 20
        let filled = Int(progress * Double(barWidth))
        let empty = barWidth - filled
        let bar = String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: empty)
        return "\r\(Color.cyan)\(fileName)\(Color.reset) (\(formatByteCount(fileSize))) \(Color.green)\(bar)\(Color.reset) \(percent)%"
    }

    func formatFileMessage(fileName: String, url: String, fileSize: Int64?) -> String {
        var line = "\(Color.bold)\u{1F4CE} \(fileName)\(Color.reset)"
        if let fileSize {
            line += " (\(formatByteCount(fileSize)))"
        }
        line += "\n  \(Color.cyan)\(url)\(Color.reset)"
        return line
    }

    func formatTypingIndicator(from jid: BareJID, state: ChatState) -> String? {
        state == .composing ? "\(Color.dim)[\(jid) is typing...]\(Color.reset)" : nil
    }

    func formatConnectionState(_ state: AccountService.ConnectionState, jid: BareJID) -> String {
        switch state {
        case .disconnected:
            return "\(Color.yellow)\(jid): disconnected\(Color.reset)"
        case .connecting:
            return "\(Color.yellow)\(jid): connecting...\(Color.reset)"
        case let .connected(fullJID):
            return "\(Color.green)\(jid): connected as \(fullJID)\(Color.reset)"
        case let .error(message):
            return "\(Color.red)\(jid): error: \(message)\(Color.reset)"
        }
    }
}
