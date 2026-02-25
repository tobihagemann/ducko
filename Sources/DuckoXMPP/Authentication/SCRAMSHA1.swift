import CryptoKit

/// SCRAM-SHA-1 mechanism (RFC 5802).
struct SCRAMSHA1: SASLMechanism {
    static let mechanismName = "SCRAM-SHA-1"

    private var state: SCRAMState<Insecure.SHA1>

    init(nonceGenerator: @Sendable @escaping () -> String = SCRAMState<Insecure.SHA1>.randomNonce) {
        self.state = SCRAMState(nonceGenerator: nonceGenerator)
    }

    mutating func start(authcid: String, password: String) -> XMLElement {
        let message = state.clientFirstMessage(authcid: authcid, password: password)
        var auth = XMLElement(name: "auth", namespace: saslNamespace, attributes: ["mechanism": Self.mechanismName])
        auth.addText(Base64.encode(message))
        return auth
    }

    mutating func handleChallenge(_ challenge: XMLElement) -> SASLAuthResponse {
        guard let encoded = challenge.textContent,
              let decoded = Base64.decodeString(encoded)
        else {
            return .failure(.invalidBase64)
        }

        switch state.clientFinalMessage(serverFirstMessage: decoded) {
        case .success(let response):
            var element = XMLElement(name: "response", namespace: saslNamespace)
            element.addText(Base64.encode(response))
            return .continueWith(element)
        case .failure(let error):
            return .failure(error)
        }
    }

    mutating func handleSuccess(_ success: XMLElement) -> SASLAuthResponse {
        guard let encoded = success.textContent,
              let decoded = Base64.decodeString(encoded)
        else {
            return .failure(.invalidBase64)
        }

        switch state.verifyServerFinal(serverFinalMessage: decoded) {
        case .success:
            return .success
        case .failure(let error):
            return .failure(error)
        }
    }
}
