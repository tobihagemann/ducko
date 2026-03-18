import CryptoKit

/// Negotiation coordinator for SASL authentication.
///
/// Picks the strongest mechanism from the server's offered list,
/// drives the `<auth>` → `<challenge>` → `<response>` → `<success>` exchange.
struct SASLAuthenticator {
    private var activeMechanism: ActiveMechanism?

    /// Creates an authenticator with a specific mechanism (for testing with known nonces).
    init(mechanism: ActiveMechanism? = nil) {
        self.activeMechanism = mechanism
    }

    // MARK: - Negotiation

    /// Parses `<mechanisms>` from stream features, selects the strongest available,
    /// and produces the initial `<auth>` element.
    mutating func begin(
        features: XMLElement,
        authcid: String,
        password: String,
        channelBindingData: [UInt8]? = nil,
        hasClientCertificate: Bool = false
    ) throws -> XMLElement {
        let offeredNames = parseMechanisms(features)
        let preferenceOrder = buildSASLPreferenceOrder(
            channelBindingData: channelBindingData,
            hasClientCertificate: hasClientCertificate
        )

        guard let selected = preferenceOrder.first(where: { offeredNames.contains($0) }) else {
            throw SASLAuthError.noSupportedMechanism
        }

        var mechanism = createMechanism(selected, channelBindingData: channelBindingData)

        // EXTERNAL doesn't use authcid/password
        if case var .external(m) = mechanism {
            let auth = m.start(authzid: nil)
            activeMechanism = .external(m)
            return auth
        }

        let auth = mechanism.start(authcid: authcid, password: password)
        activeMechanism = mechanism
        return auth
    }

    /// Dispatches a received stanza (`<challenge>`, `<success>`, or `<failure>`) to the active mechanism.
    mutating func receive(_ stanza: XMLElement) -> SASLAuthResponse {
        guard var mechanism = activeMechanism else {
            return .failure(.invalidState("No active mechanism"))
        }

        let response: SASLAuthResponse = switch stanza.name {
        case "challenge":
            mechanism.handleChallenge(stanza)
        case "success":
            mechanism.handleSuccess(stanza)
        case "failure":
            parseFailure(stanza)
        default:
            .failure(.invalidState("Unexpected SASL element: \(stanza.name)"))
        }

        activeMechanism = mechanism
        return response
    }

    // MARK: - Private

    /// Creates the appropriate mechanism instance for the selected name.
    private func createMechanism(
        _ name: String,
        channelBindingData: [UInt8]?
    ) -> ActiveMechanism {
        switch name {
        case SCRAMMechanismName.sha256Plus:
            return .scram256(SCRAM<SHA256>(
                mechanismName: name, channelBindingData: channelBindingData!
            ))
        case SCRAMMechanismName.sha256:
            let cbMode: ChannelBindingMode = channelBindingData != nil ? .clientSupportsButNotUsed : .none
            return .scram256(SCRAM<SHA256>(mechanismName: name, channelBindingMode: cbMode))
        case SCRAMMechanismName.sha1Plus:
            return .scram1(SCRAM<Insecure.SHA1>(
                mechanismName: name, channelBindingData: channelBindingData!
            ))
        case SCRAMMechanismName.sha1:
            let cbMode: ChannelBindingMode = channelBindingData != nil ? .clientSupportsButNotUsed : .none
            return .scram1(SCRAM<Insecure.SHA1>(mechanismName: name, channelBindingMode: cbMode))
        case SASLExternal.mechanismName:
            return .external(SASLExternal())
        case SASLPlain.mechanismName:
            return .plain(SASLPlain())
        default:
            preconditionFailure("Unsupported mechanism \(name) passed to createMechanism")
        }
    }

    /// Extracts mechanism names from stream features.
    ///
    /// Looks for `<mechanisms xmlns="urn:ietf:params:xml:ns:xmpp-sasl">` containing
    /// `<mechanism>NAME</mechanism>` children.
    /// - Note: Mechanism names are uppercased per RFC 4422 §3.1 (case-insensitive).
    private func parseMechanisms(_ features: XMLElement) -> Set<String> {
        guard let mechanisms = features.child(named: "mechanisms", namespace: saslNamespace) else {
            return []
        }
        return Set(mechanisms.children(named: "mechanism").compactMap { $0.textContent?.uppercased() })
    }

    /// Parses a SASL `<failure>` element into a `.serverFailure` error.
    private func parseFailure(_ failure: XMLElement) -> SASLAuthResponse {
        // The condition is the first child element (e.g. <not-authorized/>)
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

    /// Enum-based dispatch for SASL mechanism types.
    enum ActiveMechanism {
        case scram256(SCRAM<SHA256>)
        case scram1(SCRAM<Insecure.SHA1>)
        case external(SASLExternal)
        case plain(SASLPlain)

        mutating func start(authcid: String, password: String) -> XMLElement {
            switch self {
            case var .scram256(m):
                let result = m.start(authcid: authcid, password: password)
                self = .scram256(m)
                return result
            case var .scram1(m):
                let result = m.start(authcid: authcid, password: password)
                self = .scram1(m)
                return result
            case var .external(m):
                // Server determines identity from TLS client certificate
                let result = m.start(authzid: nil)
                self = .external(m)
                return result
            case var .plain(m):
                let result = m.start(authcid: authcid, password: password)
                self = .plain(m)
                return result
            }
        }

        mutating func handleChallenge(_ challenge: XMLElement) -> SASLAuthResponse {
            switch self {
            case var .scram256(m):
                let result = m.handleChallenge(challenge)
                self = .scram256(m)
                return result
            case var .scram1(m):
                let result = m.handleChallenge(challenge)
                self = .scram1(m)
                return result
            case var .external(m):
                let result = m.handleChallenge(challenge)
                self = .external(m)
                return result
            case var .plain(m):
                let result = m.handleChallenge(challenge)
                self = .plain(m)
                return result
            }
        }

        mutating func handleSuccess(_ success: XMLElement) -> SASLAuthResponse {
            switch self {
            case var .scram256(m):
                let result = m.handleSuccess(success)
                self = .scram256(m)
                return result
            case var .scram1(m):
                let result = m.handleSuccess(success)
                self = .scram1(m)
                return result
            case var .external(m):
                let result = m.handleSuccess(success)
                self = .external(m)
                return result
            case var .plain(m):
                let result = m.handleSuccess(success)
                self = .plain(m)
                return result
            }
        }
    }
}
