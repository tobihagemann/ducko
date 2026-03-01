/// A forwarded message per XEP-0297 (Stanza Forwarding).
///
/// Used by both Carbons (XEP-0280) and MAM (XEP-0313) to wrap
/// a `<message>` with an optional `<delay>` timestamp.
public struct ForwardedMessage: Sendable {
    public let message: XMPPMessage
    public let timestamp: String?

    public init(message: XMPPMessage, timestamp: String?) {
        self.message = message
        self.timestamp = timestamp
    }

    // MARK: - Parsing

    /// Parses a `<forwarded xmlns="urn:xmpp:forward:0">` element.
    public static func parse(_ element: XMLElement) -> ForwardedMessage? {
        guard element.name == "forwarded",
              element.namespace == XMPPNamespaces.forward,
              let messageElement = element.child(named: "message") else {
            return nil
        }

        let timestamp = element.child(named: "delay", namespace: XMPPNamespaces.delay)?
            .attribute("stamp")

        return ForwardedMessage(
            message: XMPPMessage(element: messageElement),
            timestamp: timestamp
        )
    }
}
