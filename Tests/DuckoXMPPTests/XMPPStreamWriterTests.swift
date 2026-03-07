import Testing
@testable import DuckoXMPP

enum XMPPStreamWriterTests {
    struct StreamOpening {
        @Test
        func `Generates valid stream opening with required attributes`() {
            let bytes = XMPPStreamWriter.streamOpening(to: "example.com")
            let xml = String(decoding: bytes, as: UTF8.self)
            #expect(xml.hasPrefix("<?xml version='1.0'?>"))
            #expect(xml.contains("xmlns=\"jabber:client\""))
            #expect(xml.contains("xmlns:stream=\"http://etherx.jabber.org/streams\""))
            #expect(xml.contains("to=\"example.com\""))
            #expect(xml.contains("version=\"1.0\""))
            #expect(xml.contains("xml:lang=\"en\""))
            #expect(xml.hasSuffix(">"))
        }

        @Test
        func `Includes from attribute when provided`() {
            let bytes = XMPPStreamWriter.streamOpening(to: "example.com", from: "user@example.com")
            let xml = String(decoding: bytes, as: UTF8.self)
            #expect(xml.contains("from=\"user@example.com\""))
        }

        @Test
        func `Omits from attribute when nil`() {
            let bytes = XMPPStreamWriter.streamOpening(to: "example.com")
            let xml = String(decoding: bytes, as: UTF8.self)
            #expect(!xml.contains("from="))
        }

        @Test
        func `Escapes special characters in domain`() {
            let bytes = XMPPStreamWriter.streamOpening(to: "a&b.com")
            let xml = String(decoding: bytes, as: UTF8.self)
            #expect(xml.contains("to=\"a&amp;b.com\""))
        }
    }

    struct StanzaSerialization {
        @Test
        func `Serializes message stanza to UTF-8 bytes`() {
            var element = XMLElement(name: "message", attributes: ["type": "chat"])
            var body = XMLElement(name: "body")
            body.addText("Hello")
            element.addChild(body)

            let bytes = XMPPStreamWriter.stanza(element)
            let xml = String(decoding: bytes, as: UTF8.self)
            #expect(xml == element.xmlString)
        }

        @Test
        func `Serializes self-closing element`() {
            let element = XMLElement(name: "presence")
            let bytes = XMPPStreamWriter.stanza(element)
            #expect(String(decoding: bytes, as: UTF8.self) == "<presence/>")
        }
    }

    struct StreamClosing {
        @Test
        func `Generates valid stream closing tag`() {
            let bytes = XMPPStreamWriter.streamClosing()
            #expect(String(decoding: bytes, as: UTF8.self) == "</stream:stream>")
        }
    }

    struct RoundTrip {
        @Test
        func `Writer output can be parsed by parser`() throws {
            var msg = XMLElement(name: "message", attributes: ["type": "chat"])
            var body = XMLElement(name: "body")
            body.addText("Hello")
            msg.addChild(body)

            let parser = XMPPStreamParser()
            var events: [XMLStreamEvent] = []
            events.append(contentsOf: parser.parse(XMPPStreamWriter.streamOpening(to: "example.com")))
            events.append(contentsOf: parser.parse(XMPPStreamWriter.stanza(msg)))
            events.append(contentsOf: parser.parse(XMPPStreamWriter.streamClosing()))
            events.append(contentsOf: parser.close())

            try #require(events.count == 3)

            guard case let .streamOpened(attrs) = events[0] else {
                Issue.record("Expected streamOpened")
                return
            }
            #expect(attrs["to"] == "example.com")

            guard case let .stanzaReceived(element) = events[1] else {
                Issue.record("Expected stanzaReceived")
                return
            }
            #expect(element.name == "message")
            #expect(element.attribute("type") == "chat")
            #expect(element.child(named: "body")?.textContent == "Hello")

            guard case .streamClosed = events[2] else {
                Issue.record("Expected streamClosed")
                return
            }
        }
    }
}
