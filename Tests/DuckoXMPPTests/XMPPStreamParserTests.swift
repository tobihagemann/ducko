import Testing
@testable import DuckoXMPP

private let streamOpenTag =
    "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' to='example.com' version='1.0'>"

private func parseChunks(_ chunks: [String]) async -> [XMLStreamEvent] {
    let parser = XMPPStreamParser()
    for chunk in chunks {
        parser.parse(Array(chunk.utf8))
    }
    parser.close()
    var events: [XMLStreamEvent] = []
    for await event in parser.events {
        events.append(event)
    }
    return events
}

// MARK: - Event Extraction Helpers

extension XMLStreamEvent {
    var streamOpenedAttributes: [String: String]? {
        guard case let .streamOpened(attrs) = self else { return nil }
        return attrs
    }

    var stanzaElement: XMLElement? {
        guard case let .stanzaReceived(element) = self else { return nil }
        return element
    }

    var isStreamClosed: Bool {
        guard case .streamClosed = self else { return false }
        return true
    }

    var isError: Bool {
        guard case .error = self else { return false }
        return true
    }
}

enum XMPPStreamParserTests {
    struct StreamLifecycle {
        @Test("Stream open emits streamOpened with attributes")
        func streamOpen() async throws {
            let events = await parseChunks([
                "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' to='example.com' from='example.com' version='1.0'>"
            ])
            try #require(events.count == 1)
            let attrs = try #require(events[0].streamOpenedAttributes)
            #expect(attrs["xmlns"] == "jabber:client")
            #expect(attrs["xmlns:stream"] == "http://etherx.jabber.org/streams")
            #expect(attrs["to"] == "example.com")
            #expect(attrs["from"] == "example.com")
            #expect(attrs["version"] == "1.0")
        }

        @Test("Stream close emits streamClosed")
        func streamClose() async throws {
            let events = await parseChunks([
                streamOpenTag,
                "</stream:stream>"
            ])
            try #require(events.count == 2)
            #expect(events[0].streamOpenedAttributes != nil)
            #expect(events[1].isStreamClosed)
        }

        @Test("Full lifecycle: open, stanza, close")
        func fullLifecycle() async throws {
            let events = await parseChunks([
                streamOpenTag,
                "<message><body>Hi</body></message>",
                "</stream:stream>"
            ])
            try #require(events.count == 3)
            #expect(events[0].streamOpenedAttributes != nil)
            #expect(events[1].stanzaElement != nil)
            #expect(events[2].isStreamClosed)
        }
    }

    struct StanzaParsing {
        @Test("Simple message stanza")
        func simpleMessage() async throws {
            let events = await parseChunks([
                streamOpenTag,
                "<message type='chat' to='user@example.com'><body>Hello</body></message>"
            ])
            try #require(events.count == 2)
            let element = try #require(events[1].stanzaElement)
            #expect(element.name == "message")
            #expect(element.attribute("type") == "chat")
            #expect(element.attribute("to") == "user@example.com")
            #expect(element.child(named: "body")?.textContent == "Hello")
        }

        @Test("Stanza with nested elements")
        func nestedElements() async throws {
            let events = await parseChunks([
                streamOpenTag,
                "<iq type='result' id='1'><query><item jid='a@b'/><item jid='c@d'/></query></iq>"
            ])
            try #require(events.count == 2)
            let element = try #require(events[1].stanzaElement)
            #expect(element.name == "iq")
            let query = try #require(element.child(named: "query"))
            let items = query.children(named: "item")
            #expect(items.count == 2)
            #expect(items[0].attribute("jid") == "a@b")
            #expect(items[1].attribute("jid") == "c@d")
        }

        @Test("Stanza with text content")
        func textContent() async throws {
            let events = await parseChunks([
                streamOpenTag,
                "<message><body>Hello &amp; goodbye</body></message>"
            ])
            try #require(events.count == 2)
            let element = try #require(events[1].stanzaElement)
            #expect(element.child(named: "body")?.textContent == "Hello & goodbye")
        }

        @Test("Stanza with namespace")
        func namespace() async throws {
            let events = await parseChunks([
                streamOpenTag,
                "<iq type='result'><query xmlns='jabber:iq:roster'><item jid='a@b'/></query></iq>"
            ])
            try #require(events.count == 2)
            let element = try #require(events[1].stanzaElement)
            let query = try #require(element.child(named: "query"))
            #expect(query.namespace == "jabber:iq:roster")
        }

        @Test("Self-closing stanza")
        func selfClosing() async throws {
            let events = await parseChunks([
                streamOpenTag,
                "<presence/>"
            ])
            try #require(events.count == 2)
            let element = try #require(events[1].stanzaElement)
            #expect(element.name == "presence")
            #expect(element.children.isEmpty)
        }

        @Test("Multiple stanzas in sequence")
        func multipleStanzas() async throws {
            let events = await parseChunks([
                streamOpenTag,
                "<message><body>One</body></message>",
                "<message><body>Two</body></message>",
                "<message><body>Three</body></message>"
            ])
            try #require(events.count == 4) // open + 3 stanzas
            for i in 1 ... 3 {
                let element = try #require(events[i].stanzaElement)
                #expect(element.name == "message")
            }
        }

        @Test("Stanza elements in content namespace have nil namespace")
        func contentNamespaceOmitted() async throws {
            let events = await parseChunks([
                streamOpenTag,
                "<message><body>Hi</body></message>"
            ])
            try #require(events.count == 2)
            let element = try #require(events[1].stanzaElement)
            #expect(element.namespace == nil)
            #expect(element.child(named: "body")?.namespace == nil)
        }
    }

    struct IncrementalParsing {
        @Test("Stanza split across two chunks")
        func splitStanza() async throws {
            let events = await parseChunks([
                streamOpenTag,
                "<message><bo",
                "dy>Hello</body></message>"
            ])
            try #require(events.count == 2)
            let element = try #require(events[1].stanzaElement)
            #expect(element.child(named: "body")?.textContent == "Hello")
        }

        @Test("Stanza split mid-attribute-value")
        func splitMidAttributeValue() async throws {
            let events = await parseChunks([
                streamOpenTag,
                "<message type='ch",
                "at' to='user@example.com'><body>Hi</body></message>"
            ])
            try #require(events.count == 2)
            let element = try #require(events[1].stanzaElement)
            #expect(element.attribute("type") == "chat")
            #expect(element.attribute("to") == "user@example.com")
        }

        @Test("Stream open and stanza in same chunk")
        func streamOpenAndStanzaSameChunk() async throws {
            let events = await parseChunks([
                streamOpenTag + "<presence/>"
            ])
            try #require(events.count == 2)
            #expect(events[0].streamOpenedAttributes != nil)
            let element = try #require(events[1].stanzaElement)
            #expect(element.name == "presence")
        }

        @Test("Byte-by-byte feeding")
        func byteByByte() async throws {
            let xml = streamOpenTag + "<message><body>Hi</body></message>"
            let parser = XMPPStreamParser()
            for byte in xml.utf8 {
                parser.parse([byte])
            }
            parser.close()
            var events: [XMLStreamEvent] = []
            for await event in parser.events {
                events.append(event)
            }
            try #require(events.count == 2)
            let element = try #require(events[1].stanzaElement)
            #expect(element.child(named: "body")?.textContent == "Hi")
        }

        @Test("Multiple stanzas in one chunk")
        func multipleStanzasOneChunk() async throws {
            let events = await parseChunks([
                streamOpenTag,
                "<presence/><message><body>Hi</body></message><iq type='get'/>"
            ])
            try #require(events.count == 4) // open + 3 stanzas
            let presence = try #require(events[1].stanzaElement)
            #expect(presence.name == "presence")
            let message = try #require(events[2].stanzaElement)
            #expect(message.name == "message")
            let iq = try #require(events[3].stanzaElement)
            #expect(iq.name == "iq")
        }
    }

    struct ErrorHandling {
        @Test("Malformed XML emits error event")
        func malformedXML() async {
            let events = await parseChunks([
                streamOpenTag,
                "<message><body>unclosed",
                "</message>"
            ])
            #expect(events.contains { $0.isError })
        }
    }
}
