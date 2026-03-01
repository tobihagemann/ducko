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
        encode([
            "type": "message",
            "direction": message.isOutgoing ? "outgoing" : "incoming",
            "from": message.fromJID,
            "body": message.body,
            "timestamp": formatTimestamp(message.timestamp)
        ])
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
        switch event {
        case let .connected(jid):
            return encode([
                "type": "connected",
                "jid": jid.description,
                "account": accountID.uuidString
            ])
        case let .disconnected(reason):
            var dict: [String: String] = [
                "type": "disconnected",
                "account": accountID.uuidString
            ]
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
        case let .authenticationFailed(message):
            return encode([
                "type": "authentication_failed",
                "message": message,
                "account": accountID.uuidString
            ])
        case let .messageReceived(message):
            guard let from = message.from?.bareJID, let body = message.body else { return nil }
            return encode([
                "type": "message",
                "direction": "incoming",
                "from": from.description,
                "body": body,
                "account": accountID.uuidString,
                "timestamp": formatTimestamp(Date())
            ])
        case let .presenceSubscriptionRequest(from: jid):
            return encode(["type": "subscription_request", "from": jid.description])
        case .presenceReceived, .iqReceived, .rosterLoaded, .rosterItemChanged, .presenceUpdated,
             .messageCarbonReceived, .messageCarbonSent, .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageError:
            return nil
        }
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
