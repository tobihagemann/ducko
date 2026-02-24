/// An XMPP `<iq>` stanza.
struct XMPPIQ: XMPPStanza {
    var element: XMLElement

    init(element: XMLElement) {
        self.element = element
    }

    init(type: IQType, to: JID? = nil, id: String? = nil) {
        var attributes: [String: String] = ["type": type.rawValue]
        if let to { attributes["to"] = to.description }
        if let id { attributes["id"] = id }
        self.element = XMLElement(name: "iq", attributes: attributes)
    }

    // MARK: - IQ Type

    enum IQType: String, Sendable {
        case get
        case set
        case result
        case error
    }

    var iqType: IQType? {
        get { type.flatMap(IQType.init(rawValue:)) }
        set { type = newValue?.rawValue }
    }

    // MARK: - Payload

    /// The first non-error child element (the IQ payload).
    var childElement: XMLElement? {
        for case .element(let child) in element.children where child.name != "error" {
            return child
        }
        return nil
    }

    // MARK: - Convenience

    var isGet: Bool { iqType == .get }
    var isSet: Bool { iqType == .set }
    var isResult: Bool { iqType == .result }
    var isError: Bool { iqType == .error }
}
