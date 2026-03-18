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
