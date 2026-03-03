import Testing
@testable import DuckoXMPP

enum XMLElementTests {
    struct Serialization {
        @Test
        func `Self-closing element`() {
            let element = XMLElement(name: "br")
            #expect(element.xmlString == "<br/>")
        }

        @Test
        func `Element with text content`() {
            var element = XMLElement(name: "body")
            element.addText("Hello")
            #expect(element.xmlString == "<body>Hello</body>")
        }

        @Test
        func `Nested elements`() {
            var child = XMLElement(name: "body")
            child.addText("Hello")
            var parent = XMLElement(name: "message")
            parent.addChild(child)
            #expect(parent.xmlString == "<message><body>Hello</body></message>")
        }

        @Test
        func `XML special character escaping`() {
            var element = XMLElement(name: "body")
            element.addText("a < b & c > d \"e\" 'f'")
            #expect(element.xmlString == "<body>a &lt; b &amp; c &gt; d &quot;e&quot; &apos;f&apos;</body>")
        }

        @Test
        func `Namespace rendered as xmlns`() {
            let element = XMLElement(name: "query", namespace: "jabber:iq:roster")
            #expect(element.xmlString == #"<query xmlns="jabber:iq:roster"/>"#)
        }

        @Test
        func `Attributes sorted by key`() {
            let element = XMLElement(name: "iq", attributes: ["type": "get", "id": "1"])
            #expect(element.xmlString == #"<iq id="1" type="get"/>"#)
        }
    }

    struct Lookup {
        @Test
        func `Find child by name`() {
            var parent = XMLElement(name: "message")
            var body = XMLElement(name: "body")
            body.addText("Hello")
            parent.addChild(body)
            parent.addChild(XMLElement(name: "subject"))

            let found = parent.child(named: "body")
            #expect(found?.textContent == "Hello")
        }

        @Test
        func `Find child by name and namespace`() {
            var parent = XMLElement(name: "iq")
            parent.addChild(XMLElement(name: "query", namespace: "jabber:iq:roster"))
            parent.addChild(XMLElement(name: "query", namespace: "jabber:iq:disco"))

            let found = parent.child(named: "query", namespace: "jabber:iq:roster")
            #expect(found?.namespace == "jabber:iq:roster")
        }

        @Test
        func `Attribute value lookup`() {
            let element = XMLElement(name: "iq", attributes: ["type": "get", "id": "abc"])
            #expect(element.attribute("type") == "get")
            #expect(element.attribute("id") == "abc")
            #expect(element.attribute("missing") == nil)
        }

        @Test
        func `Find multiple children by name`() {
            var parent = XMLElement(name: "query")
            parent.addChild(XMLElement(name: "item", attributes: ["jid": "a@b"]))
            parent.addChild(XMLElement(name: "item", attributes: ["jid": "c@d"]))
            parent.addChild(XMLElement(name: "other"))

            let items = parent.children(named: "item")
            #expect(items.count == 2)
        }
    }

    struct Mutation {
        @Test
        func `Add text child`() {
            var element = XMLElement(name: "body")
            element.addText("Hello")
            #expect(element.textContent == "Hello")
        }

        @Test
        func `Add element child`() {
            var parent = XMLElement(name: "message")
            let child = XMLElement(name: "body")
            parent.addChild(child)
            #expect(parent.child(named: "body") != nil)
        }

        @Test
        func `Set attribute`() {
            var element = XMLElement(name: "iq")
            element.setAttribute("type", value: "get")
            #expect(element.attribute("type") == "get")
        }

        @Test
        func `Overwrite attribute`() {
            var element = XMLElement(name: "iq", attributes: ["type": "get"])
            element.setAttribute("type", value: "set")
            #expect(element.attribute("type") == "set")
        }
    }

    struct TextContent {
        @Test
        func `Concatenates multiple text nodes`() {
            var element = XMLElement(name: "body")
            element.addText("Hello ")
            element.addText("World")
            #expect(element.textContent == "Hello World")
        }

        @Test
        func `Returns nil for no text content`() {
            let element = XMLElement(name: "empty")
            #expect(element.textContent == nil)
        }
    }
}
