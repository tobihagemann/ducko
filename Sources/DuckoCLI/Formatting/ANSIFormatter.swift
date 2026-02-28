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
        return "\(Color.dim)[\(timestamp)]\(Color.reset) \(color)\(direction) \(message.fromJID): \(message.body)\(Color.reset)"
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
            switch reason {
            case .requested:
                return "\(Color.yellow)disconnected\(Color.reset)"
            case let .streamError(message):
                return "\(Color.red)disconnected: stream error: \(message)\(Color.reset)"
            case let .connectionLost(message):
                return "\(Color.red)disconnected: connection lost: \(message)\(Color.reset)"
            }
        case let .authenticationFailed(message):
            return "\(Color.red)authentication failed: \(message)\(Color.reset)"
        case let .messageReceived(message):
            guard let from = message.from?.bareJID, let body = message.body else { return nil }
            let timestamp = iso8601(Date())
            return "\(Color.dim)[\(timestamp)]\(Color.reset) \(Color.green)<- \(from): \(body)\(Color.reset)"
        case .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged,
             .presenceUpdated, .presenceSubscriptionRequest:
            return nil
        }
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
