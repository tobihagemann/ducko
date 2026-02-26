/// An XMPP `<iq>` stanza.
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
