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
            guard let from = message.from?.bareJID, let body = message.body else { return nil }
            let timestamp = iso8601(Date())
            return "[\(timestamp)] <- \(from): \(body)"
        case let .presenceSubscriptionRequest(from: jid):
            return "Subscription request from \(jid)"
        case let .deliveryReceiptReceived(messageID, from):
            return "delivery receipt: \(messageID) from \(from.bareJID)"
        case let .messageCorrected(_, newBody, from):
            return "message corrected by \(from.bareJID): \(newBody)"
        case let .messageError(_, from, errorText):
            return "message error from \(from.bareJID): \(errorText)"
        case .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged,
             .presenceUpdated,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .chatMarkerReceived,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomSubjectChanged, .roomInviteReceived, .roomMessageReceived:
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
