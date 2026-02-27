import Foundation

enum CLIError: Error, LocalizedError {
    case noAccounts
    case accountNotFound(String)
    case noPassword
    case invalidJID(String)
    case connectionFailed(String)
    case connectionTimeout

    var errorDescription: String? {
        switch self {
        case .noAccounts:
            "No accounts configured. Use the GUI or create one first."
        case let .accountNotFound(id):
            "Account not found: \(id)"
        case .noPassword:
            "No password provided. Set DUCKO_PASSWORD or run in a terminal."
        case let .invalidJID(jid):
            "Invalid JID: \(jid)"
        case let .connectionFailed(message):
            "Connection failed: \(message)"
        case .connectionTimeout:
            "Connection timed out after 30 seconds"
        }
    }
}
