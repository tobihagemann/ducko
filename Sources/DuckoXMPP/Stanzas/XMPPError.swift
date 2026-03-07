/// XMPP stream-level errors per RFC 6120 §4.9.3.
public enum XMPPStreamError: String, Sendable {
    case badFormat = "bad-format"
    case badNamespacePrefix = "bad-namespace-prefix"
    case conflict
    case connectionTimeout = "connection-timeout"
    case hostGone = "host-gone"
    case hostUnknown = "host-unknown"
    case improperAddressing = "improper-addressing"
    case internalServerError = "internal-server-error"
    case invalidFrom = "invalid-from"
    case invalidNamespace = "invalid-namespace"
    case invalidXML = "invalid-xml"
    case notAuthorized = "not-authorized"
    case notWellFormed = "not-well-formed"
    case policyViolation = "policy-violation"
    case remoteConnectionFailed = "remote-connection-failed"
    case reset
    case resourceConstraint = "resource-constraint"
    case restrictedXML = "restricted-xml"
    case seeOtherHost = "see-other-host"
    case systemShutdown = "system-shutdown"
    case undefinedCondition = "undefined-condition"
    case unsupportedEncoding = "unsupported-encoding"
    case unsupportedFeature = "unsupported-feature"
    case unsupportedStanzaType = "unsupported-stanza-type"
    case unsupportedVersion = "unsupported-version"

    /// Parses a stream error condition from a `<stream:error>` element.
    public static func parse(from element: XMLElement) -> XMPPStreamError? {
        for case let .element(child) in element.children
            where child.namespace == XMPPNamespaces.streams {
            if let condition = XMPPStreamError(rawValue: child.name) {
                return condition
            }
        }
        return nil
    }
}

// MARK: - XMPPStanzaError

/// XMPP stanza-level error per RFC 6120 §8.3.3.
public struct XMPPStanzaError: Sendable, Error {
    public let errorType: ErrorType
    public let condition: Condition
    public let text: String?

    public init(errorType: ErrorType, condition: Condition, text: String? = nil) {
        self.errorType = errorType
        self.condition = condition
        self.text = text
    }

    /// Human-readable description: prefers `text`, falls back to `condition.rawValue`.
    public var displayText: String {
        text ?? condition.rawValue
    }

    /// Parses a stanza error from an `<error>` child element.
    public static func parse(from element: XMLElement?) -> XMPPStanzaError? {
        guard let element else { return nil }

        let errorType = element.attribute("type").flatMap(ErrorType.init(rawValue:)) ?? .cancel

        var condition: Condition?
        var text: String?
        for case let .element(child) in element.children where child.namespace == XMPPNamespaces.stanzas {
            if child.name == "text" {
                text = child.textContent
            } else if let parsed = Condition(rawValue: child.name) {
                condition = parsed
            }
        }

        guard let condition else { return nil }
        return XMPPStanzaError(errorType: errorType, condition: condition, text: text)
    }

    public enum ErrorType: String, Sendable {
        case auth
        case cancel
        case `continue`
        case modify
        case wait
    }

    public enum Condition: String, Sendable {
        case badRequest = "bad-request"
        case conflict
        case featureNotImplemented = "feature-not-implemented"
        case forbidden
        case gone
        case internalServerError = "internal-server-error"
        case itemNotFound = "item-not-found"
        case jidMalformed = "jid-malformed"
        case notAcceptable = "not-acceptable"
        case notAllowed = "not-allowed"
        case notAuthorized = "not-authorized"
        case policyViolation = "policy-violation"
        case recipientUnavailable = "recipient-unavailable"
        case redirect
        case registrationRequired = "registration-required"
        case remoteServerNotFound = "remote-server-not-found"
        case remoteServerTimeout = "remote-server-timeout"
        case resourceConstraint = "resource-constraint"
        case serviceUnavailable = "service-unavailable"
        case subscriptionRequired = "subscription-required"
        case undefinedCondition = "undefined-condition"
        case unexpectedRequest = "unexpected-request"
    }
}
