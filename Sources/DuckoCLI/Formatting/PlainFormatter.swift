import DuckoCore
import DuckoXMPP
import Foundation

struct PlainFormatter: CLIFormatter {
    func formatMessage(_ message: ChatMessage) -> String {
        let timestamp = iso8601(message.timestamp)
        let direction = message.isOutgoing ? "->" : "<-"
        return "[\(timestamp)] \(direction) \(message.fromJID): \(message.body)"
    }

    func formatContact(_ contact: Contact) -> String {
        let name = contact.name ?? contact.jid.description
        return "\(name) (\(contact.jid)) [\(contact.subscription.rawValue)]"
    }

    func formatAccount(_ account: Account) -> String {
        "\(account.jid) (\(account.id))"
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
            switch reason {
            case .requested:
                return "disconnected"
            case let .streamError(message):
                return "disconnected: stream error: \(message)"
            case let .connectionLost(message):
                return "disconnected: connection lost: \(message)"
            }
        case let .authenticationFailed(message):
            return "authentication failed: \(message)"
        case let .messageReceived(message):
            guard let from = message.from?.bareJID, let body = message.body else { return nil }
            let timestamp = iso8601(Date())
            return "[\(timestamp)] <- \(from): \(body)"
        case .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged,
             .presenceUpdated, .presenceSubscriptionRequest:
            return nil
        }
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
