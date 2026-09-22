public struct XMPPIQ: XMPPStanza {
    public var element: XMLElement

    public init(element: XMLElement) {
        self.element = element
    }

    public init(type: IQType, to: JID? = nil, id: String? = nil) {
        var attributes: [String: String] = ["type": type.rawValue]
        if let to { attributes["to"] = to.description }
        if let id { attributes["id"] = id }
        self.element = XMLElement(name: "iq", attributes: attributes)
    }

    // MARK: - IQ Type

    public enum IQType: String, Sendable {
        case get
        case set
        case result
        case error
    }

    public var iqType: IQType? {
        get { type.flatMap(IQType.init(rawValue:)) }
        set { type = newValue?.rawValue }
    }

    // MARK: - Payload

    /// The first non-error child element (the IQ payload).
    public var childElement: XMLElement? {
        for case let .element(child) in element.children where child.name != "error" {
            return child
        }
        return nil
    }

    // MARK: - Replies

    /// Builds an empty result reply to `request`, or `nil` when the request carries no id to answer.
    public static func resultReply(for request: XMPPIQ) -> XMPPIQ? {
        guard let id = request.id else { return nil }
        return XMPPIQ(type: .result, to: request.from, id: id)
    }

    /// Builds an error reply to `request`, or `nil` when the request carries no id to answer.
    public static func errorReply(
        for request: XMPPIQ,
        type: XMPPStanzaError.ErrorType,
        condition: XMPPStanzaError.Condition,
        applicationCondition: XMLElement? = nil
    ) -> XMPPIQ? {
        guard let id = request.id else { return nil }
        return errorReply(
            id: id, to: request.from, payload: request.childElement,
            type: type, condition: condition, applicationCondition: applicationCondition
        )
    }

    /// Builds an error reply that echoes the request's payload (RFC 6120 §8.3.1).
    public static func errorReply(
        id: String,
        to: JID?,
        payload: XMLElement?,
        type: XMPPStanzaError.ErrorType,
        condition: XMPPStanzaError.Condition,
        applicationCondition: XMLElement? = nil
    ) -> XMPPIQ {
        var reply = XMPPIQ(type: .error, to: to, id: id)
        if let payload { reply.element.addChild(payload) }
        var error = XMLElement(name: "error", attributes: ["type": type.rawValue])
        error.addChild(XMLElement(name: condition.rawValue, namespace: XMPPNamespaces.stanzas))
        if let applicationCondition { error.addChild(applicationCondition) }
        reply.element.addChild(error)
        return reply
    }

    // MARK: - Sender

    /// Whether the IQ comes from the account itself: no `from`, or exactly the own bare JID (RFC 6121 §2.1.6).
    /// Reads the raw attribute, so an unparseable `from` is rejected instead of passing as absent.
    func isFromOwnAccount(_ ownJID: BareJID?) -> Bool {
        guard let rawFrom = element.attribute("from") else { return true }
        guard let ownJID, let from = JID.parse(rawFrom), case let .bare(bare) = from else { return false }
        return bare == ownJID
    }

    // MARK: - Convenience

    public var isGet: Bool {
        iqType == .get
    }

    public var isSet: Bool {
        iqType == .set
    }

    public var isResult: Bool {
        iqType == .result
    }

    public var isError: Bool {
        iqType == .error
    }
}
