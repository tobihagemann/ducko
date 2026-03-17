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
}
