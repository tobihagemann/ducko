/// Base protocol for XMPP stanzas (message, presence, iq).
protocol XMPPStanza: Sendable {
    var element: XMLElement { get set }
}

extension XMPPStanza {
    var to: JID? {
        get { element.attribute("to").flatMap(JID.parse) }
        set { element.attributes["to"] = newValue?.description }
    }

    var from: JID? {
        get { element.attribute("from").flatMap(JID.parse) }
        set { element.attributes["from"] = newValue?.description }
    }

    var id: String? {
        get { element.attribute("id") }
        set { element.attributes["id"] = newValue }
    }

    var type: String? {
        get { element.attribute("type") }
        set { element.attributes["type"] = newValue }
    }
}
