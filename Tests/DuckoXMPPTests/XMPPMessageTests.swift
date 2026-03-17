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
}
