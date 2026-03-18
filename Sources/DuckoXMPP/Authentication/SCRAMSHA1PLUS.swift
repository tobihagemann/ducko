import CryptoKit

/// SCRAM-SHA-1-PLUS mechanism (RFC 5802 channel binding).
struct SCRAMSHA1PLUS {
    static let mechanismName = "SCRAM-SHA-1-PLUS"

    private var state: SCRAMState<Insecure.SHA1>

    init(
        channelBindingData: [UInt8],
        nonceGenerator: @Sendable @escaping () -> String = SCRAMState<Insecure.SHA1>.randomNonce
    ) {
        self.state = SCRAMState(
            channelBindingMode: .bound(type: tlsServerEndPointCBType, data: channelBindingData),
            nonceGenerator: nonceGenerator
        )
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
        case let .success(response):
            var element = XMLElement(name: "response", namespace: saslNamespace)
            element.addText(Base64.encode(response))
            return .continueWith(element)
        case let .failure(error):
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
        case let .failure(error):
            return .failure(error)
        }
    }
}
