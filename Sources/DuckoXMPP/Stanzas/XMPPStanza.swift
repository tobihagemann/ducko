/// Base protocol for XMPP stanzas (message, presence, iq).
public protocol XMPPStanza: Sendable {
    var element: XMLElement { get set }
}

extension XMPPStanza {
    public var to: JID? {
        get { element.attribute("to").flatMap(JID.parse) }
        set { element.attributes["to"] = newValue?.description }
    }

    public var from: JID? {
        get { element.attribute("from").flatMap(JID.parse) }
        set { element.attributes["from"] = newValue?.description }
    }

    public var id: String? {
        get { element.attribute("id") }
        set { element.attributes["id"] = newValue }
    }

    public var type: String? {
        get { element.attribute("type") }
        set { element.attributes["type"] = newValue }
    }
}
