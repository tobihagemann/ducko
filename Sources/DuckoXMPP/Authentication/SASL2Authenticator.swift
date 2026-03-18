import CryptoKit

/// Parsed inline feature advertisement from SASL2 stream features.
struct SASL2Features {
    let mechanisms: Set<String>
    let supportsBind2: Bool
    let supportsSM: Bool
    let supportsISR: Bool
    /// XEP-0440 server-advertised channel binding types.
    /// When non-empty, PLUS mechanisms are only offered if the server supports `tls-server-end-point`.
    let channelBindingTypes: Set<String>
}

/// Negotiation coordinator for SASL2 authentication (XEP-0388).
///
/// Drives the `<authenticate>` → `<challenge>` → `<response>` → `<success>` exchange
/// using the SASL2 namespace with inline Bind 2 (XEP-0386) feature negotiation.
struct SASL2Authenticator {
    /// Result of a successful SASL2 authentication.
    struct AuthResult {
        let fullJID: FullJID
        /// The `<bound>` element from Bind 2, if present.
        let bound: XMLElement?
    }

    /// Result of a SASL2 exchange step.
    enum Response {
        case continueWith(XMLElement)
        case success(AuthResult)
        case failure(SASLAuthError)
    }

    private var activeMechanism: ActiveMechanism?

    // MARK: - Feature Parsing

    /// Parses `<authentication xmlns='urn:xmpp:sasl:2'>` from stream features.
    static func parseFeatures(_ features: XMLElement) -> SASL2Features? {
        guard let auth = features.child(named: "authentication", namespace: XMPPNamespaces.sasl2) else {
            return nil
        }

        let mechanisms = Set(
            auth.children(named: "mechanism").compactMap { $0.textContent?.uppercased() }
        )
        guard !mechanisms.isEmpty else { return nil }

        let inline = auth.child(named: "inline")
        let supportsBind2 = inline?.child(named: "bind", namespace: XMPPNamespaces.bind2) != nil
        let supportsSM = inline?.child(named: "sm", namespace: XMPPNamespaces.sm) != nil
        let supportsISR = inline?.child(named: "isr", namespace: XMPPNamespaces.isr) != nil

        // XEP-0440: SASL Channel-Binding Type Capability
        let cbTypes = Set(
            auth.child(named: "sasl-channel-binding", namespace: XMPPNamespaces.saslChannelBinding)?
                .children(named: "channel-binding")
                .compactMap { $0.attribute("type") } ?? []
        )

        return SASL2Features(
            mechanisms: mechanisms,
            supportsBind2: supportsBind2,
            supportsSM: supportsSM,
            supportsISR: supportsISR,
            channelBindingTypes: cbTypes
        )
    }

    // MARK: - Negotiation

    /// Selects the strongest mechanism and produces the `<authenticate>` element.
    /// The `inlinePayloads` are added as children (e.g., Bind 2 request).
    mutating func begin(
        features: XMLElement,
        authcid: String,
        password: String,
        inlinePayloads: [XMLElement],
        channelBindingData: [UInt8]? = nil,
        hasClientCertificate: Bool = false
    ) throws -> XMLElement {
        guard let sasl2Features = Self.parseFeatures(features) else {
            throw SASLAuthError.noSupportedMechanism
        }

        // XEP-0440: Only use CB data if the server supports tls-server-end-point
        // (or doesn't advertise any types, meaning no filtering)
        let effectiveCBData: [UInt8]? = if let channelBindingData,
                                           sasl2Features.channelBindingTypes.isEmpty
                                           || sasl2Features.channelBindingTypes.contains(tlsServerEndPointCBType) {
            channelBindingData
        } else {
            nil
        }

        let preferenceOrder = buildSASLPreferenceOrder(
            channelBindingData: effectiveCBData,
            hasClientCertificate: hasClientCertificate
        )

        guard let selected = preferenceOrder.first(where: { sasl2Features.mechanisms.contains($0) }) else {
            throw SASLAuthError.noSupportedMechanism
        }

        let (mechanism, initialPayload) = startMechanism(
            selected, authcid: authcid, password: password, channelBindingData: effectiveCBData
        )
        activeMechanism = mechanism

        var authenticate = XMLElement(
            name: "authenticate",
            namespace: XMPPNamespaces.sasl2,
            attributes: ["mechanism": selected]
        )

        var initialResponse = XMLElement(name: "initial-response")
        // EXTERNAL sends "=" for empty initial response per RFC 6120 §6.4.2
        initialResponse.addText(initialPayload.isEmpty ? "=" : Base64.encode(initialPayload))
        authenticate.addChild(initialResponse)

        for payload in inlinePayloads {
            authenticate.addChild(payload)
        }

        return authenticate
    }

    /// Dispatches a received stanza (`<challenge>`, `<success>`, or `<failure>`) to the active mechanism.
    mutating func receive(_ stanza: XMLElement) -> Response {
        guard var mechanism = activeMechanism else {
            return .failure(.invalidState("No active mechanism"))
        }

        let response: Response = switch stanza.name {
        case "challenge":
            handleChallenge(stanza, mechanism: &mechanism)
        case "success":
            handleSuccess(stanza, mechanism: &mechanism)
        case "failure":
            parseFailure(stanza)
        default:
            .failure(.invalidState("Unexpected SASL2 element: \(stanza.name)"))
        }

        activeMechanism = mechanism
        return response
    }

    // MARK: - Private: Mechanism Dispatch

    private func startMechanism(
        _ name: String,
        authcid: String,
        password: String,
        channelBindingData: [UInt8]?
    ) -> (ActiveMechanism, String) {
        switch name {
        case SCRAMSHA256PLUS.mechanismName:
            var scram = SCRAMState<SHA256>(
                channelBindingMode: .bound(type: tlsServerEndPointCBType, data: channelBindingData!)
            )
            let payload = scram.clientFirstMessage(authcid: authcid, password: password)
            return (.scramSHA256Plus(scram), payload)
        case SCRAMSHA256.mechanismName:
            let cbMode: ChannelBindingMode = channelBindingData != nil ? .clientSupportsButNotUsed : .none
            var scram = SCRAMState<SHA256>(channelBindingMode: cbMode)
            let payload = scram.clientFirstMessage(authcid: authcid, password: password)
            return (.scramSHA256(scram), payload)
        case SCRAMSHA1PLUS.mechanismName:
            var scram = SCRAMState<Insecure.SHA1>(
                channelBindingMode: .bound(type: tlsServerEndPointCBType, data: channelBindingData!)
            )
            let payload = scram.clientFirstMessage(authcid: authcid, password: password)
            return (.scramSHA1Plus(scram), payload)
        case SCRAMSHA1.mechanismName:
            let cbMode: ChannelBindingMode = channelBindingData != nil ? .clientSupportsButNotUsed : .none
            var scram = SCRAMState<Insecure.SHA1>(channelBindingMode: cbMode)
            let payload = scram.clientFirstMessage(authcid: authcid, password: password)
            return (.scramSHA1(scram), payload)
        case SASLExternal.mechanismName:
            return (.external, "")
        case SASLPlain.mechanismName:
            let payload = "\0\(authcid)\0\(password)"
            return (.plain, payload)
        default:
            preconditionFailure("Unsupported mechanism \(name) passed to startMechanism")
        }
    }

    private func handleChallenge(_ stanza: XMLElement, mechanism: inout ActiveMechanism) -> Response {
        guard let encoded = stanza.textContent,
              let decoded = Base64.decodeString(encoded) else {
            return .failure(.invalidBase64)
        }

        switch mechanism {
        case var .scramSHA256Plus(scram):
            let response = scramChallengeResponse(decoded, scram: &scram)
            mechanism = .scramSHA256Plus(scram)
            return response
        case var .scramSHA256(scram):
            let response = scramChallengeResponse(decoded, scram: &scram)
            mechanism = .scramSHA256(scram)
            return response
        case var .scramSHA1Plus(scram):
            let response = scramChallengeResponse(decoded, scram: &scram)
            mechanism = .scramSHA1Plus(scram)
            return response
        case var .scramSHA1(scram):
            let response = scramChallengeResponse(decoded, scram: &scram)
            mechanism = .scramSHA1(scram)
            return response
        case .external:
            return .failure(.invalidState("EXTERNAL does not expect challenges"))
        case .plain:
            return .failure(.invalidState("PLAIN does not expect challenges"))
        }
    }

    private func handleSuccess(_ stanza: XMLElement, mechanism: inout ActiveMechanism) -> Response {
        // Verify SCRAM server signature from <additional-data> (required for SCRAM mechanisms)
        switch mechanism {
        case var .scramSHA256Plus(scram):
            if let error = verifyScramSignature(stanza, scram: &scram) { return error }
            mechanism = .scramSHA256Plus(scram)
        case var .scramSHA256(scram):
            if let error = verifyScramSignature(stanza, scram: &scram) { return error }
            mechanism = .scramSHA256(scram)
        case var .scramSHA1Plus(scram):
            if let error = verifyScramSignature(stanza, scram: &scram) { return error }
            mechanism = .scramSHA1Plus(scram)
        case var .scramSHA1(scram):
            if let error = verifyScramSignature(stanza, scram: &scram) { return error }
            mechanism = .scramSHA1(scram)
        case .external, .plain:
            break
        }

        return parseSuccessJID(stanza)
    }

    // MARK: - Private: SCRAM Helpers

    /// Processes a SCRAM challenge and produces the response element.
    private func scramChallengeResponse<H: HashFunction>(
        _ decoded: String,
        scram: inout SCRAMState<H>
    ) -> Response where H.Digest: Sendable {
        switch scram.clientFinalMessage(serverFirstMessage: decoded) {
        case let .success(response):
            var element = XMLElement(name: "response", namespace: XMPPNamespaces.sasl2)
            element.addText(Base64.encode(response))
            return .continueWith(element)
        case let .failure(error):
            return .failure(error)
        }
    }

    /// Verifies the SCRAM server signature from `<additional-data>`.
    /// Returns an error response if verification fails, `nil` on success.
    private func verifyScramSignature<H: HashFunction>(
        _ stanza: XMLElement,
        scram: inout SCRAMState<H>
    ) -> Response? where H.Digest: Sendable {
        guard let additionalData = stanza.childText(named: "additional-data"),
              let decoded = Base64.decodeString(additionalData) else {
            return .failure(.invalidState("Missing additional-data for SCRAM server verification"))
        }
        let result = scram.verifyServerFinal(serverFinalMessage: decoded)
        if case let .failure(error) = result { return .failure(error) }
        return nil
    }

    /// Parses the authorization-identifier and bound element from a SASL2 success.
    private func parseSuccessJID(_ stanza: XMLElement) -> Response {
        guard let jidStr = stanza.childText(named: "authorization-identifier"),
              let fullJID = FullJID.parse(jidStr) else {
            return .failure(.invalidState("No JID in SASL2 success"))
        }

        let bound = stanza.child(named: "bound", namespace: XMPPNamespaces.bind2)
        return .success(AuthResult(fullJID: fullJID, bound: bound))
    }

    /// Parses a SASL2 `<failure>` element into an error.
    private func parseFailure(_ failure: XMLElement) -> Response {
        var condition = "unknown"
        var text: String?
        for case let .element(child) in failure.children {
            if child.name == "text" {
                text = child.textContent
            } else {
                condition = child.name
            }
        }
        return .failure(.serverFailure(condition: condition, text: text))
    }

    // MARK: - Active Mechanism

    private enum ActiveMechanism {
        case scramSHA256Plus(SCRAMState<SHA256>)
        case scramSHA256(SCRAMState<SHA256>)
        case scramSHA1Plus(SCRAMState<Insecure.SHA1>)
        case scramSHA1(SCRAMState<Insecure.SHA1>)
        case external
        case plain
    }
}

// MARK: - Bind 2

/// Builds a Bind 2 request element for inclusion in SASL2 `<authenticate>`.
func buildBind2Request(
    tag: String = "Ducko",
    enableSM: Bool = false,
    enableISR: Bool = false,
    enableCarbons: Bool = false
) -> XMLElement {
    var bind = XMLElement(name: "bind", namespace: XMPPNamespaces.bind2)

    var tagElement = XMLElement(name: "tag")
    tagElement.addText(tag)
    bind.addChild(tagElement)

    if enableSM {
        var smEnable = XMLElement(
            name: "enable",
            namespace: XMPPNamespaces.sm,
            attributes: ["resume": "true"]
        )
        if enableISR {
            smEnable.addChild(XMLElement(
                name: "isr-enable",
                namespace: XMPPNamespaces.isr,
                attributes: ["mechanism": XMPPNamespaces.isrMechanism]
            ))
        }
        bind.addChild(smEnable)
    }

    if enableCarbons {
        bind.addChild(XMLElement(name: "enable", namespace: XMPPNamespaces.carbons))
    }

    return bind
}

// MARK: - ISR

/// Builds an ISR resume authenticate element for SASL2.
func buildISRAuthenticate(token: String, smResumeElement: XMLElement) -> XMLElement {
    var auth = XMLElement(
        name: "authenticate",
        namespace: XMPPNamespaces.sasl2,
        attributes: ["mechanism": XMPPNamespaces.isrMechanism]
    )

    var initialResponse = XMLElement(name: "initial-response")
    initialResponse.addText(Base64.encode(Array(token.utf8)))
    auth.addChild(initialResponse)

    var instResume = XMLElement(name: "inst-resume", namespace: XMPPNamespaces.isr)
    instResume.addChild(smResumeElement)
    auth.addChild(instResume)

    return auth
}
