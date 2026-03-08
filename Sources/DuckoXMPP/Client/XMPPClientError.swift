/// Errors from XMPP client operations.
enum XMPPClientError: Error {
    case notConnected
    case alreadyConnected
    case tlsNegotiationFailed(String)
    case authenticationFailed(String)
    case bindingFailed(String)
    case sessionFailed(String)
    case unexpectedStreamState(String)
    case timeout
}
