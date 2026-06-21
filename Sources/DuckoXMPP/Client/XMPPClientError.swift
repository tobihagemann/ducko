/// Errors from XMPP client operations.
public enum XMPPClientError: Error {
    case notConnected
    case alreadyConnected
    case tlsRequired
    case tlsNegotiationFailed(String)
    case authenticationFailed(String)
    case bindingFailed(String)
    case sessionFailed(String)
    case unexpectedStreamState(String)
    case timeout
    case streamManagementBusy
    /// The configured domain could not be converted to an A-label for DNS/TLS lookup.
    case invalidDomain(String)
}
