import Testing
@testable import DuckoXMPP

enum XMPPMessageTests {
    struct MessageType {
        @Test
        func `Missing type returns normal`() {
            let element = XMLElement(name: "message", attributes: ["from": "contact@example.com"])
            let message = XMPPMessage(element: element)
            #expect(message.messageType == .normal)
        }

        @Test
        func `Unrecognized type returns normal`() {
            let element = XMLElement(name: "message", attributes: ["type": "foo"])
            let message = XMPPMessage(element: element)
            #expect(message.messageType == .normal)
        }

        @Test
        func `Chat type returns chat`() {
            let message = XMPPMessage(type: .chat)
            #expect(message.messageType == .chat)
        }

        @Test
        func `Groupchat type returns groupchat`() {
            let message = XMPPMessage(type: .groupchat)
            #expect(message.messageType == .groupchat)
        }

        @Test
        func `Error type returns error`() {
            let message = XMPPMessage(type: .error)
            #expect(message.messageType == .error)
        }

        @Test
        func `Headline type returns headline`() {
            let message = XMPPMessage(type: .headline)
            #expect(message.messageType == .headline)
        }

        @Test
        func `Normal type returns normal`() {
            let message = XMPPMessage(type: .normal)
            #expect(message.messageType == .normal)
        }
    }

    struct Thread {
        @Test
        func `Thread getter returns child text`() {
            var element = XMLElement(name: "message", attributes: ["type": "chat"])
            var threadChild = XMLElement(name: "thread")
            threadChild.addText("abc-123")
            element.addChild(threadChild)
            let message = XMPPMessage(element: element)
            #expect(message.thread == "abc-123")
        }

        @Test
        func `Thread setter creates child element`() {
            var message = XMPPMessage(type: .chat)
            message.thread = "xyz-456"
            #expect(message.thread == "xyz-456")
        }

        @Test
        func `Thread is nil when not present`() {
            let message = XMPPMessage(type: .chat)
            #expect(message.thread == nil)
        }

        @Test
        func `Thread setter clears child element`() {
            var message = XMPPMessage(type: .chat)
            message.thread = "to-be-removed"
            message.thread = nil
            #expect(message.thread == nil)
        }
    }

    struct ThreadParent {
        @Test
        func `Returns parent attribute from thread element`() {
            var element = XMLElement(name: "message", attributes: ["type": "chat"])
            var threadChild = XMLElement(name: "thread", attributes: ["parent": "parent-thread-id"])
            threadChild.addText("child-thread-id")
            element.addChild(threadChild)
            let message = XMPPMessage(element: element)
            #expect(message.threadParent == "parent-thread-id")
        }

        @Test
        func `Returns nil when thread has no parent attribute`() {
            var element = XMLElement(name: "message", attributes: ["type": "chat"])
            var threadChild = XMLElement(name: "thread")
            threadChild.addText("abc-123")
            element.addChild(threadChild)
            let message = XMPPMessage(element: element)
            #expect(message.threadParent == nil)
        }

        @Test
        func `Returns nil when no thread element`() {
            let message = XMPPMessage(type: .chat)
            #expect(message.threadParent == nil)
        }
    }

    struct OOB {
        @Test
        func `Returns OOB data with URL and description`() {
            var element = XMLElement(name: "message", attributes: ["type": "chat"])
            var oobX = XMLElement(name: "x", namespace: XMPPNamespaces.oob)
            var urlChild = XMLElement(name: "url")
            urlChild.addText("https://example.com/photo.jpg")
            var descChild = XMLElement(name: "desc")
            descChild.addText("A photo")
            oobX.addChild(urlChild)
            oobX.addChild(descChild)
            element.addChild(oobX)
            let message = XMPPMessage(element: element)
            #expect(message.oobData.count == 1)
            #expect(message.oobData[0].url == "https://example.com/photo.jpg")
            #expect(message.oobData[0].desc == "A photo")
        }

        @Test
        func `Returns empty when no OOB elements`() {
            let message = XMPPMessage(type: .chat)
            #expect(message.oobData.isEmpty)
        }

        @Test
        func `Returns multiple OOB entries`() {
            var element = XMLElement(name: "message", attributes: ["type": "chat"])
            for urlString in ["https://example.com/a.jpg", "https://example.com/b.pdf"] {
                var oobX = XMLElement(name: "x", namespace: XMPPNamespaces.oob)
                var urlChild = XMLElement(name: "url")
                urlChild.addText(urlString)
                oobX.addChild(urlChild)
                element.addChild(oobX)
            }
            let message = XMPPMessage(element: element)
            #expect(message.oobData.count == 2)
            #expect(message.oobData[0].url == "https://example.com/a.jpg")
            #expect(message.oobData[1].url == "https://example.com/b.pdf")
        }

        @Test
        func `Skips OOB with empty URL`() {
            var element = XMLElement(name: "message", attributes: ["type": "chat"])
            var oobX = XMLElement(name: "x", namespace: XMPPNamespaces.oob)
            let urlChild = XMLElement(name: "url")
            oobX.addChild(urlChild)
            element.addChild(oobX)
            let message = XMPPMessage(element: element)
            #expect(message.oobData.isEmpty)
        }

        @Test
        func `Returns OOB data without description`() {
            var element = XMLElement(name: "message", attributes: ["type": "chat"])
            var oobX = XMLElement(name: "x", namespace: XMPPNamespaces.oob)
            var urlChild = XMLElement(name: "url")
            urlChild.addText("https://example.com/file.zip")
            oobX.addChild(urlChild)
            element.addChild(oobX)
            let message = XMPPMessage(element: element)
            #expect(message.oobData.count == 1)
            #expect(message.oobData[0].url == "https://example.com/file.zip")
            #expect(message.oobData[0].desc == nil)
        }
    }
}
