import Testing

@testable import DuckoXMPP

struct XMPPStreamWriterTests {
    struct StreamOpening {
        @Test("Generates valid stream opening with required attributes")
        func basic() {
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

        @Test("Includes from attribute when provided")
        func withFrom() {
            let bytes = XMPPStreamWriter.streamOpening(to: "example.com", from: "user@example.com")
            let xml = String(decoding: bytes, as: UTF8.self)
            #expect(xml.contains("from=\"user@example.com\""))
        }

        @Test("Omits from attribute when nil")
        func withoutFrom() {
            let bytes = XMPPStreamWriter.streamOpening(to: "example.com")
            let xml = String(decoding: bytes, as: UTF8.self)
            #expect(!xml.contains("from="))
        }

        @Test("Escapes special characters in domain")
        func escapedDomain() {
            let bytes = XMPPStreamWriter.streamOpening(to: "a&b.com")
            let xml = String(decoding: bytes, as: UTF8.self)
            #expect(xml.contains("to=\"a&amp;b.com\""))
        }
    }

    struct StanzaSerialization {
        @Test("Serializes message stanza to UTF-8 bytes")
        func message() {
            var element = XMLElement(name: "message", attributes: ["type": "chat"])
            var body = XMLElement(name: "body")
            body.addText("Hello")
            element.addChild(body)

            let bytes = XMPPStreamWriter.stanza(element)
            let xml = String(decoding: bytes, as: UTF8.self)
            #expect(xml == element.xmlString)
        }

        @Test("Serializes self-closing element")
        func selfClosing() {
            let element = XMLElement(name: "presence")
            let bytes = XMPPStreamWriter.stanza(element)
            #expect(String(decoding: bytes, as: UTF8.self) == "<presence/>")
        }
    }

    struct StreamClosing {
        @Test("Generates valid stream closing tag")
        func closing() {
            let bytes = XMPPStreamWriter.streamClosing()
            #expect(String(decoding: bytes, as: UTF8.self) == "</stream:stream>")
        }
    }

    struct RoundTrip {
        @Test("Writer output can be parsed by parser")
        func roundTrip() async throws {
            var msg = XMLElement(name: "message", attributes: ["type": "chat"])
            var body = XMLElement(name: "body")
            body.addText("Hello")
            msg.addChild(body)

            let parser = XMPPStreamParser()
            parser.parse(XMPPStreamWriter.streamOpening(to: "example.com"))
            parser.parse(XMPPStreamWriter.stanza(msg))
            parser.parse(XMPPStreamWriter.streamClosing())
            parser.close()

            var events: [XMLStreamEvent] = []
            for await event in parser.events {
                events.append(event)
            }

            try #require(events.count == 3)

            guard case .streamOpened(let attrs) = events[0] else {
                Issue.record("Expected streamOpened")
                return
            }
            #expect(attrs["to"] == "example.com")

            guard case .stanzaReceived(let element) = events[1] else {
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
