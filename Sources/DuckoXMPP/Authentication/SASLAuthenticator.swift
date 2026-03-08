/// Negotiation coordinator for SASL authentication.
///
/// Picks the strongest mechanism from the server's offered list,
/// drives the `<auth>` → `<challenge>` → `<response>` → `<success>` exchange.
struct SASLAuthenticator {
    private var activeMechanism: ActiveMechanism?

    /// Mechanisms in preference order (strongest first).
    private static let preferenceOrder: [String] = [
        SCRAMSHA256.mechanismName,
        SCRAMSHA1.mechanismName,
        SASLPlain.mechanismName
    ]

    /// Creates an authenticator with a specific mechanism (for testing with known nonces).
    init(mechanism: ActiveMechanism? = nil) {
        self.activeMechanism = mechanism
    }

    // MARK: - Negotiation

    /// Parses `<mechanisms>` from stream features, selects the strongest available,
    /// and produces the initial `<auth>` element.
    mutating func begin(features: XMLElement, authcid: String, password: String) throws -> XMLElement {
        let offeredNames = parseMechanisms(features)

        guard let selected = Self.preferenceOrder.first(where: { offeredNames.contains($0) }) else {
            throw SASLAuthError.noSupportedMechanism
        }

        var mechanism: ActiveMechanism
        switch selected {
        case SCRAMSHA256.mechanismName:
            mechanism = .scramSHA256(SCRAMSHA256())
        case SCRAMSHA1.mechanismName:
            mechanism = .scramSHA1(SCRAMSHA1())
        case SASLPlain.mechanismName:
            mechanism = .plain(SASLPlain())
        default:
            throw SASLAuthError.noSupportedMechanism
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
        case scramSHA256(SCRAMSHA256)
        case scramSHA1(SCRAMSHA1)
        case plain(SASLPlain)

        mutating func start(authcid: String, password: String) -> XMLElement {
            switch self {
            case var .scramSHA256(m):
                let result = m.start(authcid: authcid, password: password)
                self = .scramSHA256(m)
                return result
            case var .scramSHA1(m):
                let result = m.start(authcid: authcid, password: password)
                self = .scramSHA1(m)
                return result
            case var .plain(m):
                let result = m.start(authcid: authcid, password: password)
                self = .plain(m)
                return result
            }
        }

        mutating func handleChallenge(_ challenge: XMLElement) -> SASLAuthResponse {
            switch self {
            case var .scramSHA256(m):
                let result = m.handleChallenge(challenge)
                self = .scramSHA256(m)
                return result
            case var .scramSHA1(m):
                let result = m.handleChallenge(challenge)
                self = .scramSHA1(m)
                return result
            case var .plain(m):
                let result = m.handleChallenge(challenge)
                self = .plain(m)
                return result
            }
        }

        mutating func handleSuccess(_ success: XMLElement) -> SASLAuthResponse {
            switch self {
            case var .scramSHA256(m):
                let result = m.handleSuccess(success)
                self = .scramSHA256(m)
                return result
            case var .scramSHA1(m):
                let result = m.handleSuccess(success)
                self = .scramSHA1(m)
                return result
            case var .plain(m):
                let result = m.handleSuccess(success)
                self = .plain(m)
                return result
            }
        }
    }
}
