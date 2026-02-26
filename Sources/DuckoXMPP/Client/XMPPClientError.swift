/// Errors from XMPP client operations.
public enum XMPPClientError: Error, Sendable {
    case notConnected
    case alreadyConnected
    case streamError(String)
    case tlsRequired
    case tlsNegotiationFailed(String)
    case authenticationFailed(String)
    case bindingFailed(String)
    case sessionFailed(String)
    case unexpectedStreamState(String)
    case timeout
}
