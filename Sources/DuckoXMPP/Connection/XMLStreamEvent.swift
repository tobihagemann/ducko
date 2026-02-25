/// Events emitted by the XML stream parser during XMPP stream processing.
enum XMLStreamEvent: Sendable {
    /// The opening `<stream:stream>` tag has been received.
    case streamOpened(attributes: [String: String])
    /// A complete top-level stanza has been received.
    case stanzaReceived(XMLElement)
    /// The closing `</stream:stream>` tag has been received.
    case streamClosed
    /// A parse error occurred.
    case error(XMLStreamParseError)
}

/// An error encountered during XML stream parsing.
struct XMLStreamParseError: Error, Sendable {
    let message: String
}
