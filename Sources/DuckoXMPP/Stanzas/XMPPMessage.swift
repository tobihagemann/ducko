/// An XMPP `<message>` stanza.
public struct XMPPMessage: XMPPStanza {
    public var element: XMLElement

    public init(element: XMLElement) {
        self.element = element
    }

    public init(type: MessageType = .chat, to: JID? = nil, id: String? = nil) {
        var attributes: [String: String] = ["type": type.rawValue]
        if let to { attributes["to"] = to.description }
        if let id { attributes["id"] = id }
        self.element = XMLElement(name: "message", attributes: attributes)
    }

    // MARK: - Message Type

    public enum MessageType: String, Sendable {
        case chat
        case groupchat
        case headline
        case normal
        case error
    }

    public var messageType: MessageType? {
        get { type.flatMap(MessageType.init(rawValue:)) }
        set { type = newValue?.rawValue }
    }

    // MARK: - Child Elements

    public var body: String? {
        get { element.childText(named: "body") }
        set { element.setChildText(named: "body", to: newValue) }
    }

    public var subject: String? {
        get { element.childText(named: "subject") }
        set { element.setChildText(named: "subject", to: newValue) }
    }

    /// Whether the message contains a XEP-0393 `<unstyled/>` hint.
    public var isUnstyled: Bool {
        element.child(named: "unstyled", namespace: XMPPNamespaces.styling) != nil
    }
}
