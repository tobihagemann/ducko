import DuckoCore
import DuckoXMPP
import Foundation

struct JSONFormatter: CLIFormatter {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    // MARK: - CLIFormatter

    func formatMessage(_ message: ChatMessage) -> String {
        var dict: [String: String] = [
            "type": "message",
            "direction": message.isOutgoing ? "outgoing" : "incoming",
            "from": message.fromJID,
            "body": message.body,
            "timestamp": formatTimestamp(message.timestamp)
        ]
        if message.isDelivered {
            dict["delivered"] = "true"
        }
        if message.isEdited {
            dict["edited"] = "true"
        }
        if let errorText = message.errorText {
            dict["error"] = errorText
        }
        return encode(dict)
    }

    func formatContact(_ contact: Contact) -> String {
        var dict: [String: String] = [
            "type": "contact",
            "jid": contact.jid.description,
            "subscription": contact.subscription.rawValue
        ]
        if let name = contact.name {
            dict["name"] = name
        }
        return encode(dict)
    }

    func formatAccount(_ account: Account) -> String {
        encode([
            "type": "account",
            "id": account.id.uuidString,
            "jid": account.jid.description,
            "isEnabled": account.isEnabled ? "true" : "false"
        ])
    }

    func formatContactWithPresence(_ contact: Contact, presence: PresenceService.PresenceStatus?) -> String {
        var dict: [String: String] = [
            "type": "contact",
            "jid": contact.jid.description,
            "subscription": contact.subscription.rawValue,
            "presence": (presence ?? .offline).rawValue
        ]
        if let name = contact.name {
            dict["name"] = name
        }
        if let localAlias = contact.localAlias {
            dict["localAlias"] = localAlias
        }
        if !contact.groups.isEmpty {
            dict["groups"] = contact.groups.joined(separator: ",")
        }
        return encode(dict)
    }

    func formatGroupHeader(_ group: ContactGroup) -> String {
        encode([
            "type": "group_header",
            "name": group.name,
            "count": "\(group.contacts.count)"
        ])
    }

    func formatPresence(jid: BareJID, status: String, message: String?) -> String {
        var dict: [String: String] = [
            "type": "presence",
            "jid": jid.description,
            "status": status
        ]
        if let message {
            dict["message"] = message
        }
        return encode(dict)
    }

    func formatError(_ error: any Error) -> String {
        encode([
            "type": "error",
            "message": error.localizedDescription
        ])
    }

    func formatEvent(_ event: XMPPEvent, accountID: UUID) -> String? {
        let account = accountID.uuidString
        switch event {
        case let .connected(jid):
            return encode(["type": "connected", "jid": jid.description, "account": account])
        case let .disconnected(reason):
            return formatDisconnect(reason, account: account)
        case let .authenticationFailed(message):
            return encode(["type": "authentication_failed", "message": message, "account": account])
        case let .messageReceived(message):
            return formatIncomingMessage(message, account: account)
        case let .presenceSubscriptionRequest(from: jid):
            return encode(["type": "subscription_request", "from": jid.description])
        case let .deliveryReceiptReceived(messageID, from):
            return encode(["type": "delivery_receipt", "messageID": messageID, "from": from.bareJID.description, "account": account])
        case let .messageCorrected(originalID, newBody, from):
            return encode(["type": "message_corrected", "originalID": originalID, "newBody": newBody, "from": from.bareJID.description, "account": account])
        case let .messageError(_, from, errorText):
            return encode(["type": "message_error", "from": from.bareJID.description, "error": errorText, "account": account])
        case .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged,
             .presenceUpdated,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .chatMarkerReceived:
            return nil
        }
    }

    private func formatDisconnect(_ reason: DisconnectReason, account: String) -> String {
        var dict: [String: String] = ["type": "disconnected", "account": account]
        switch reason {
        case .requested:
            dict["reason"] = "requested"
        case let .streamError(message):
            dict["reason"] = "stream_error"
            dict["message"] = message
        case let .connectionLost(message):
            dict["reason"] = "connection_lost"
            dict["message"] = message
        }
        return encode(dict)
    }

    private func formatIncomingMessage(_ message: XMPPMessage, account: String) -> String? {
        guard let from = message.from?.bareJID, let body = message.body else { return nil }
        return encode([
            "type": "message", "direction": "incoming", "from": from.description,
            "body": body, "account": account, "timestamp": formatTimestamp(Date())
        ])
    }

    func formatTypingIndicator(from jid: BareJID, state: ChatState) -> String? {
        encode([
            "type": "typing",
            "jid": jid.description,
            "state": state.rawValue
        ])
    }

    func formatConnectionState(_ state: AccountService.ConnectionState, jid: BareJID) -> String {
        var dict: [String: String] = [
            "type": "connection_state",
            "jid": jid.description
        ]
        switch state {
        case .disconnected:
            dict["state"] = "disconnected"
        case .connecting:
            dict["state"] = "connecting"
        case let .connected(fullJID):
            dict["state"] = "connected"
            dict["fullJID"] = fullJID.description
        case let .error(message):
            dict["state"] = "error"
            dict["message"] = message
        }
        return encode(dict)
    }

    // MARK: - Private

    private func encode(_ dict: [String: String]) -> String {
        guard let data = try? encoder.encode(dict),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    /// ISO 8601 without fractional seconds for cleaner JSON output.
    private func formatTimestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }
}
