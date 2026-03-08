/// A single MAM (XEP-0313) result containing a forwarded message.
public struct ArchivedMessage: Sendable {
    public let messageID: String
    public let serverID: String?
    public let forwarded: ForwardedMessage

    public init(messageID: String, serverID: String?, forwarded: ForwardedMessage) {
        self.messageID = messageID
        self.serverID = serverID
        self.forwarded = forwarded
    }

    // MARK: - Parsing

    /// Parses a `<result xmlns="urn:xmpp:mam:2">` element.
    public static func parse(_ element: XMLElement) -> ArchivedMessage? {
        guard element.name == "result",
              element.namespace == XMPPNamespaces.mam,
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
            messageID: messageID,
            serverID: serverID,
            forwarded: forwarded
        )
    }
}
