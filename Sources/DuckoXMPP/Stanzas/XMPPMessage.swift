/// An XMPP `<message>` stanza.
struct XMPPMessage: XMPPStanza {
    var element: XMLElement

    init(element: XMLElement) {
        self.element = element
    }

    init(type: MessageType = .chat, to: JID? = nil, id: String? = nil) {
        var attributes: [String: String] = ["type": type.rawValue]
        if let to { attributes["to"] = to.description }
        if let id { attributes["id"] = id }
        self.element = XMLElement(name: "message", attributes: attributes)
    }

    // MARK: - Message Type

    enum MessageType: String, Sendable {
        case chat
        case groupchat
        case headline
        case normal
        case error
    }

    var messageType: MessageType? {
        get { type.flatMap(MessageType.init(rawValue:)) }
        set { type = newValue?.rawValue }
    }

    // MARK: - Child Elements

    var body: String? {
        get { element.childText(named: "body") }
        set { element.setChildText(named: "body", to: newValue) }
    }

    var subject: String? {
        get { element.childText(named: "subject") }
        set { element.setChildText(named: "subject", to: newValue) }
    }

    var thread: String? {
        get { element.childText(named: "thread") }
        set { element.setChildText(named: "thread", to: newValue) }
    }
}
