/// SASL namespace per RFC 6120 §6.
let saslNamespace = "urn:ietf:params:xml:ns:xmpp-sasl"

/// Channel binding type for `tls-server-end-point` (RFC 5929 §4.1).
let tlsServerEndPointCBType = "tls-server-end-point"

/// Result of a SASL exchange step.
enum SASLAuthResponse {
    case continueWith(XMLElement)
    case success
    case failure(SASLAuthError)
}

/// Errors that can occur during SASL authentication.
enum SASLAuthError: Error {
    case noSupportedMechanism
    case invalidBase64
    case malformedChallenge(String)
    case invalidServerNonce
    case serverSignatureMismatch
    case serverFailure(condition: String, text: String?)
    case invalidState(String)
    case iterationCountTooLow(Int)

    /// Human-readable description. A `.serverFailure` prefers the server's `text`, then a phrase for a known
    /// condition, then the raw condition name.
    var displayText: String {
        switch self {
        case .noSupportedMechanism: "The server offers no supported authentication mechanism"
        case .invalidBase64: "The server sent malformed authentication data"
        case let .malformedChallenge(reason): "The server sent a malformed challenge: \(reason)"
        case .invalidServerNonce: "The server sent an invalid nonce"
        case .serverSignatureMismatch: "The server could not prove it knows the password"
        case let .serverFailure(condition, text): text ?? Condition(rawValue: condition)?.displayText ?? condition
        case let .invalidState(reason): "Unexpected authentication state: \(reason)"
        case let .iterationCountTooLow(count): "The server's password hashing is too weak (\(count) iterations)"
        }
    }

    /// Parses a SASL or SASL2 `<failure>` element into a `.serverFailure` error.
    static func parse(failure: XMLElement) -> SASLAuthError {
        var condition = "unknown"
        var text: String?
        for case let .element(child) in failure.children {
            if child.name == "text" {
                text = child.textContent
            } else {
                condition = child.name
            }
        }
        return .serverFailure(condition: condition, text: text)
    }

    /// SASL failure conditions per RFC 6120 §6.5.
    enum Condition: String {
        case aborted
        case accountDisabled = "account-disabled"
        case credentialsExpired = "credentials-expired"
        case encryptionRequired = "encryption-required"
        case incorrectEncoding = "incorrect-encoding"
        case invalidAuthzid = "invalid-authzid"
        case invalidMechanism = "invalid-mechanism"
        case malformedRequest = "malformed-request"
        case mechanismTooWeak = "mechanism-too-weak"
        case notAuthorized = "not-authorized"
        case temporaryAuthFailure = "temporary-auth-failure"

        var displayText: String {
            switch self {
            case .aborted: "Aborted by the server"
            case .accountDisabled: "The account is disabled"
            case .credentialsExpired: "The password has expired"
            case .encryptionRequired: "The server requires an encrypted connection"
            case .incorrectEncoding, .malformedRequest: "The server rejected a malformed authentication request"
            case .invalidAuthzid: "The server rejected the authorization identity"
            case .invalidMechanism: "The server rejected the authentication mechanism"
            case .mechanismTooWeak: "The server requires a stronger authentication mechanism"
            case .notAuthorized: "Incorrect username or password"
            case .temporaryAuthFailure: "Temporary server failure, try again later"
            }
        }
    }
}

/// Builds SASL mechanism preference order based on available capabilities.
///
/// Shared between ``SASLAuthenticator`` (SASL1) and ``SASL2Authenticator`` (SASL2).
func buildSASLPreferenceOrder(
    channelBindingData: [UInt8]?,
    hasClientCertificate: Bool
) -> [String] {
    var order: [String] = []
    if hasClientCertificate { order.append(SASLExternal.mechanismName) }
    if channelBindingData != nil { order.append(SCRAMMechanismName.sha256Plus) }
    order.append(SCRAMMechanismName.sha256)
    if channelBindingData != nil { order.append(SCRAMMechanismName.sha1Plus) }
    order.append(SCRAMMechanismName.sha1)
    order.append(SASLPlain.mechanismName)
    return order
}
