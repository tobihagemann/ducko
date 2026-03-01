import Foundation

enum CLIError: Error, LocalizedError {
    case noAccounts
    case accountNotFound(String)
    case noPassword
    case invalidJID(String)
    case connectionFailed(String)
    case connectionTimeout
    case invalidPresenceStatus(String)
    case invalidDate(String)

    var errorDescription: String? {
        switch self {
        case .noAccounts:
            "No accounts configured. Run 'ducko account add <jid>' to add one."
        case let .accountNotFound(id):
            "Account not found: \(id)"
        case .noPassword:
            "No password provided. Run in a terminal to enter interactively."
        case let .invalidJID(jid):
            "Invalid JID: \(jid)"
        case let .connectionFailed(message):
            "Connection failed: \(message)"
        case .connectionTimeout:
            "Connection timed out after 30 seconds"
        case let .invalidPresenceStatus(status):
            "Invalid presence status: \(status). Valid values: available, away, xa, dnd, offline"
        case let .invalidDate(string):
            "Invalid ISO 8601 date: \(string)"
        }
    }
}
