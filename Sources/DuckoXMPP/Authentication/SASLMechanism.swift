/// SASL namespace per RFC 6120 §6.
let saslNamespace = "urn:ietf:params:xml:ns:xmpp-sasl"

/// Result of a SASL exchange step.
enum SASLAuthResponse: Sendable {
    case continueWith(XMLElement)
    case success
    case failure(SASLAuthError)
}

/// Errors that can occur during SASL authentication.
enum SASLAuthError: Error, Sendable {
    case noSupportedMechanism
    case invalidBase64
    case malformedChallenge(String)
    case invalidServerNonce
    case serverSignatureMismatch
    case serverFailure(condition: String, text: String?)
    case invalidState(String)
    case iterationCountTooLow(Int)
}

/// A SASL authentication mechanism.
protocol SASLMechanism: Sendable {
    /// The IANA-registered mechanism name (e.g. "SCRAM-SHA-256").
    static var mechanismName: String { get }

    /// Produces the initial `<auth>` element to send to the server.
    mutating func start(authcid: String, password: String) -> XMLElement

    /// Handles a `<challenge>` from the server.
    mutating func handleChallenge(_ challenge: XMLElement) -> SASLAuthResponse

    /// Handles a `<success>` from the server.
    mutating func handleSuccess(_ success: XMLElement) -> SASLAuthResponse
}
