import DuckoCore
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCLI

struct JSONFormatterTests {
    let formatter = JSONFormatter()

    @Test func outputIsValidJSON() throws {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "alice@example.com",
            body: "Hello!",
            timestamp: Date(),
            isOutgoing: false,
            isRead: false,
            isDelivered: false,
            isEdited: false,
            type: "chat"
        )
        let output = formatter.formatMessage(message)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "message")
        #expect(json["from"] == "alice@example.com")
        #expect(json["body"] == "Hello!")
        #expect(json["direction"] == "incoming")
    }

    @Test func eventConnectedContainsAccountField() throws {
        let accountID = UUID()
        let jid = try #require(FullJID.parse("alice@example.com/res"))
        let output = try #require(formatter.formatEvent(.connected(jid), accountID: accountID))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "connected")
        #expect(json["account"] == accountID.uuidString)
    }

    @Test func iqEventReturnsNil() {
        let iq = XMPPIQ(type: .result)
        let output = formatter.formatEvent(.iqReceived(iq), accountID: UUID())
        #expect(output == nil)
    }

    @Test func presenceEventReturnsNil() {
        let presence = XMPPPresence()
        let output = formatter.formatEvent(.presenceReceived(presence), accountID: UUID())
        #expect(output == nil)
    }
}
