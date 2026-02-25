/// Serializes XMPP stream-level XML to UTF-8 bytes.
enum XMPPStreamWriter {
    /// Generates the XML declaration and `<stream:stream>` opening tag.
    static func streamOpening(
        to domain: String,
        from jid: String? = nil,
        version: String = "1.0",
        xmlLang: String = "en"
    ) -> [UInt8] {
        var xml = "<?xml version='1.0'?>"
        xml += "<stream:stream"
        xml += " xmlns=\"jabber:client\""
        xml += " xmlns:stream=\"http://etherx.jabber.org/streams\""
        xml += " to=\"\(XMLElement.escape(domain))\""
        if let jid {
            xml += " from=\"\(XMLElement.escape(jid))\""
        }
        xml += " version=\"\(XMLElement.escape(version))\""
        xml += " xml:lang=\"\(XMLElement.escape(xmlLang))\""
        xml += ">"
        return Array(xml.utf8)
    }

    /// Serializes an ``XMLElement`` stanza to UTF-8 bytes.
    static func stanza(_ element: XMLElement) -> [UInt8] {
        Array(element.xmlString.utf8)
    }

    /// Generates the closing `</stream:stream>` tag.
    static func streamClosing() -> [UInt8] {
        Array("</stream:stream>".utf8)
    }
}
