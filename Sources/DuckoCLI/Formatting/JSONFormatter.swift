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
            "timestamp": iso8601(message.timestamp)
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
                "timestamp": iso8601(Date())
            ])
        case .presenceReceived, .iqReceived:
            return nil
        }
    }

    func formatConnectionState(_ state: AccountService.ConnectionState, jid: BareJID) -> String {
        switch state {
        case .disconnected:
            return encode(["type": "connection_state", "jid": jid.description, "state": "disconnected"])
        case .connecting:
            return encode(["type": "connection_state", "jid": jid.description, "state": "connecting"])
        case let .connected(fullJID):
            return encode(["type": "connection_state", "jid": jid.description, "state": "connected", "fullJID": fullJID.description])
        case let .error(message):
            return encode(["type": "connection_state", "jid": jid.description, "state": "error", "message": message])
        }
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

    private func iso8601(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }
}
