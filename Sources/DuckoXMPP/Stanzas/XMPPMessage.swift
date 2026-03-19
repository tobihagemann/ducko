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
        get {
            // RFC 6121 §5.2.2: Treat missing or unrecognized type as "normal".
            guard let type else { return .normal }
            return MessageType(rawValue: type) ?? .normal
        }
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

    // MARK: - Multi-Language Content (RFC 6121 §5.2.3/5.2.4)

    /// A text element with an optional `xml:lang` attribute.
    public struct LocalizedText: Sendable, Equatable {
        public let lang: String?
        public let text: String
    }

    /// All `<body>` elements with their `xml:lang` attributes.
    public var localizedBodies: [LocalizedText] {
        element.children(named: "body").compactMap { child in
            guard let text = child.textContent else { return nil }
            return LocalizedText(lang: child.attribute("xml:lang"), text: text)
        }
    }

    /// All `<subject>` elements with their `xml:lang` attributes.
    public var localizedSubjects: [LocalizedText] {
        element.children(named: "subject").compactMap { child in
            guard let text = child.textContent else { return nil }
            return LocalizedText(lang: child.attribute("xml:lang"), text: text)
        }
    }

    public var thread: String? {
        get { element.childText(named: "thread") }
        set { element.setChildText(named: "thread", to: newValue) }
    }

    /// The `parent` attribute of the `<thread>` element per RFC 6121 §5.2.5.
    public var threadParent: String? {
        element.child(named: "thread")?.attribute("parent")
    }

    /// Whether the message contains a XEP-0393 `<unstyled/>` hint.
    public var isUnstyled: Bool {
        element.child(named: "unstyled", namespace: XMPPNamespaces.styling) != nil
    }

    // MARK: - XEP-0066 Out-of-Band Data

    public struct OOBData: Sendable {
        public let url: String
        public let desc: String?
    }

    /// XEP-0066 Out-of-Band Data attachments (`<x xmlns='jabber:x:oob'>`).
    public var oobData: [OOBData] {
        element.children(named: "x")
            .filter { $0.namespace == XMPPNamespaces.oob }
            .compactMap { oob -> OOBData? in
                guard let url = oob.child(named: "url")?.textContent, !url.isEmpty else { return nil }
                return OOBData(url: url, desc: oob.child(named: "desc")?.textContent)
            }
    }
}
