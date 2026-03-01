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

    @Test func accountOutputIsValidJSON() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let accountID = UUID()
        let account = Account(
            id: accountID,
            jid: jid,
            isEnabled: true,
            connectOnLaunch: false,
            createdAt: Date()
        )
        let output = formatter.formatAccount(account)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "account")
        #expect(json["jid"] == "alice@example.com")
        #expect(json["id"] == accountID.uuidString)
        #expect(json["isEnabled"] == "true")
    }

    // MARK: - formatContactWithPresence

    @Test func contactWithPresenceIsValidJSON() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let contact = Contact(
            id: UUID(),
            accountID: UUID(),
            jid: jid,
            name: "Alice",
            subscription: .both,
            groups: ["Friends"],
            isBlocked: false,
            createdAt: Date()
        )
        let output = formatter.formatContactWithPresence(contact, presence: .available)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "contact")
        #expect(json["jid"] == "alice@example.com")
        #expect(json["presence"] == "available")
        #expect(json["name"] == "Alice")
        #expect(json["groups"] == "Friends")
    }

    @Test func contactNilPresenceShowsOffline() throws {
        let jid = try #require(BareJID.parse("bob@example.com"))
        let contact = Contact(
            id: UUID(),
            accountID: UUID(),
            jid: jid,
            subscription: .to,
            groups: [],
            isBlocked: false,
            createdAt: Date()
        )
        let output = formatter.formatContactWithPresence(contact, presence: nil)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["presence"] == "offline")
    }

    // MARK: - formatGroupHeader

    @Test func groupHeaderIsValidJSON() throws {
        let group = try ContactGroup(id: "friends", name: "Friends", contacts: [
            Contact(
                id: UUID(),
                accountID: UUID(),
                jid: #require(BareJID.parse("a@example.com")),
                subscription: .both,
                groups: [],
                isBlocked: false,
                createdAt: Date()
            ),
            Contact(
                id: UUID(),
                accountID: UUID(),
                jid: #require(BareJID.parse("b@example.com")),
                subscription: .both,
                groups: [],
                isBlocked: false,
                createdAt: Date()
            ),
            Contact(
                id: UUID(),
                accountID: UUID(),
                jid: #require(BareJID.parse("c@example.com")),
                subscription: .both,
                groups: [],
                isBlocked: false,
                createdAt: Date()
            )
        ])
        let output = formatter.formatGroupHeader(group)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "group_header")
        #expect(json["name"] == "Friends")
        #expect(json["count"] == "3")
    }

    // MARK: - formatEvent

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

    @Test func subscriptionRequestIsValidJSON() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let output = try #require(formatter.formatEvent(.presenceSubscriptionRequest(from: jid), accountID: UUID()))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "subscription_request")
        #expect(json["from"] == "alice@example.com")
    }

    @Test func presenceEventReturnsNil() {
        let presence = XMPPPresence()
        let output = formatter.formatEvent(.presenceReceived(presence), accountID: UUID())
        #expect(output == nil)
    }

    // MARK: - Message Markers

    @Test func messageIncludesDelivered() throws {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "bob@example.com",
            body: "Hi",
            timestamp: Date(),
            isOutgoing: true,
            isRead: true,
            isDelivered: true,
            isEdited: false,
            type: "chat"
        )
        let output = formatter.formatMessage(message)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["delivered"] == "true")
    }

    @Test func messageIncludesEdited() throws {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "alice@example.com",
            body: "corrected",
            timestamp: Date(),
            isOutgoing: false,
            isRead: false,
            isDelivered: false,
            isEdited: true,
            type: "chat"
        )
        let output = formatter.formatMessage(message)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["edited"] == "true")
    }

    // MARK: - New Event Types

    @Test func deliveryReceiptEventIsValidJSON() throws {
        let jid = try #require(JID.parse("alice@example.com/res"))
        let output = try #require(formatter.formatEvent(.deliveryReceiptReceived(messageID: "msg-1", from: jid), accountID: UUID()))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "delivery_receipt")
        #expect(json["messageID"] == "msg-1")
        #expect(json["from"] == "alice@example.com")
    }

    // MARK: - Typing Indicator

    @Test func typingIndicatorComposing() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let output = try #require(formatter.formatTypingIndicator(from: jid, state: .composing))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "typing")
        #expect(json["state"] == "composing")
    }

    @Test func typingIndicatorPaused() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let output = try #require(formatter.formatTypingIndicator(from: jid, state: .paused))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "typing")
        #expect(json["state"] == "paused")
    }
}
