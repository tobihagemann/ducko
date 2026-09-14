import DuckoXMPP
import Foundation

// DuckoXMPP must not import Foundation, so its error types gain `LocalizedError` here. Without it,
// `error.localizedDescription` renders as "The operation couldn't be completed. (DuckoXMPP.XMPPClientError error 4.)".

extension XMPPClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to the server"
        case .alreadyConnected: "Already connected to the server"
        case .tlsRequired: "The server does not offer a secure connection"
        case let .tlsNegotiationFailed(reason): "Secure connection failed: \(reason)"
        case let .authenticationFailed(reason): "Authentication failed: \(reason)"
        case let .bindingFailed(reason): "The server did not bind a resource: \(reason)"
        case let .sessionFailed(reason): "The server did not establish a session: \(reason)"
        case let .unexpectedStreamState(reason): "Unexpected response from the server: \(reason)"
        case .timeout: "The server did not respond in time"
        case .streamManagementBusy: "Stream management is busy"
        case let .invalidDomain(domain): "Invalid server domain: \(domain)"
        }
    }
}

extension XMPPStanzaError: LocalizedError {
    public var errorDescription: String? {
        "Server error: \(displayText)"
    }
}
