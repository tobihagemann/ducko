/// SASL EXTERNAL mechanism (RFC 4422 / XEP-0178).
///
/// Used with client TLS certificates. The authorization identity is sent
/// as the initial response (base64-encoded), or `=` for empty authzid.
struct SASLExternal {
    static let mechanismName = "EXTERNAL"

    mutating func start(authzid: String?) -> XMLElement {
        var auth = XMLElement(name: "auth", namespace: saslNamespace, attributes: ["mechanism": Self.mechanismName])
        if let authzid, !authzid.isEmpty {
            auth.addText(Base64.encode(authzid))
        } else {
            auth.addText("=") // RFC 6120 §6.4.2: "=" means empty initial response
        }
        return auth
    }

    mutating func handleChallenge(_: XMLElement) -> SASLAuthResponse {
        .failure(.invalidState("EXTERNAL does not expect challenges"))
    }

    mutating func handleSuccess(_: XMLElement) -> SASLAuthResponse {
        .success
    }
}
