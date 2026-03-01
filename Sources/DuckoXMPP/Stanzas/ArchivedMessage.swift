/// A single MAM (XEP-0313) result containing a forwarded message.
public struct ArchivedMessage: Sendable {
    public let queryID: String
    public let messageID: String
    public let serverID: String?
    public let forwarded: ForwardedMessage

    public init(queryID: String, messageID: String, serverID: String?, forwarded: ForwardedMessage) {
        self.queryID = queryID
        self.messageID = messageID
        self.serverID = serverID
        self.forwarded = forwarded
    }

    // MARK: - Parsing

    /// Parses a `<result xmlns="urn:xmpp:mam:2">` element.
    public static func parse(_ element: XMLElement) -> ArchivedMessage? {
        guard element.name == "result",
              element.namespace == XMPPNamespaces.mam,
              let queryID = element.attribute("queryid"),
              let messageID = element.attribute("id"),
              let forwardedElement = element.child(named: "forwarded", namespace: XMPPNamespaces.forward),
              let forwarded = ForwardedMessage.parse(forwardedElement) else {
            return nil
        }

        // XEP-0359 stanza-id
        let serverID = forwarded.message.element
            .child(named: "stanza-id", namespace: XMPPNamespaces.stanzaID)?
            .attribute("id")

        return ArchivedMessage(
            queryID: queryID,
            messageID: messageID,
            serverID: serverID,
            forwarded: forwarded
        )
    }
}
