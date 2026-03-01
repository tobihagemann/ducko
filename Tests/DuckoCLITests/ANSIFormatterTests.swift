import DuckoCore
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCLI

struct ANSIFormatterTests {
    let formatter = ANSIFormatter()

    @Test func outputContainsANSIEscapeCodes() {
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
        #expect(output.contains("\u{001B}["))
    }

    @Test func accountUsesBoldAndDim() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let account = Account(
            id: UUID(),
            jid: jid,
            isEnabled: true,
            connectOnLaunch: false,
            createdAt: Date()
        )
        let output = formatter.formatAccount(account)
        #expect(output.contains("\u{001B}[1m")) // bold
        #expect(output.contains("\u{001B}[2m")) // dim
        #expect(output.contains("alice@example.com"))
    }

    @Test func errorUsesRedCode() {
        let output = formatter.formatError(CLIError.connectionTimeout)
        #expect(output.contains("\u{001B}[31m"))
    }

    @Test func incomingMessageUsesGreen() {
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
        #expect(output.contains("\u{001B}[32m"))
    }

    // MARK: - formatContactWithPresence

    @Test func contactAvailableUsesGreen() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let contact = Contact(
            id: UUID(),
            accountID: UUID(),
            jid: jid,
            name: "Alice",
            subscription: .both,
            groups: [],
            isBlocked: false,
            createdAt: Date()
        )
        let output = formatter.formatContactWithPresence(contact, presence: .available)
        #expect(output.contains("\u{001B}[32m")) // green
        #expect(output.contains("●"))
    }

    @Test func contactAwayUsesYellow() throws {
        let jid = try #require(BareJID.parse("bob@example.com"))
        let contact = Contact(
            id: UUID(),
            accountID: UUID(),
            jid: jid,
            name: "Bob",
            subscription: .to,
            groups: [],
            isBlocked: false,
            createdAt: Date()
        )
        let output = formatter.formatContactWithPresence(contact, presence: .away)
        #expect(output.contains("\u{001B}[33m")) // yellow
    }

    @Test func contactDNDUsesRed() throws {
        let jid = try #require(BareJID.parse("carol@example.com"))
        let contact = Contact(
            id: UUID(),
            accountID: UUID(),
            jid: jid,
            name: "Carol",
            subscription: .both,
            groups: [],
            isBlocked: false,
            createdAt: Date()
        )
        let output = formatter.formatContactWithPresence(contact, presence: .dnd)
        #expect(output.contains("\u{001B}[31m")) // red
    }

    @Test func contactOfflineUsesDim() throws {
        let jid = try #require(BareJID.parse("dave@example.com"))
        let contact = Contact(
            id: UUID(),
            accountID: UUID(),
            jid: jid,
            name: "Dave",
            subscription: .both,
            groups: [],
            isBlocked: false,
            createdAt: Date()
        )
        let output = formatter.formatContactWithPresence(contact, presence: nil)
        #expect(output.contains("\u{001B}[2m")) // dim
        #expect(output.contains("○"))
    }

    @Test func subscriptionRequestUsesYellow() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let output = try #require(formatter.formatEvent(.presenceSubscriptionRequest(from: jid), accountID: UUID()))
        #expect(output.contains("\u{001B}[33m")) // yellow
        #expect(output.contains("alice@example.com"))
        #expect(output.contains("/approve"))
    }

    @Test func outgoingMessageUsesCyan() {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "bob@example.com",
            body: "Hi",
            timestamp: Date(),
            isOutgoing: true,
            isRead: true,
            isDelivered: false,
            isEdited: false,
            type: "chat"
        )
        let output = formatter.formatMessage(message)
        #expect(output.contains("\u{001B}[36m"))
    }

    // MARK: - Message Markers

    @Test func deliveredShowsCheckmark() {
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
        #expect(output.contains("\u{2713}"))
    }

    @Test func editedShowsDimMarker() {
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
        #expect(output.contains("[edited]"))
        #expect(output.contains("\u{001B}[2m")) // dim
    }

    // MARK: - Event Markers

    @Test func deliveryReceiptEventUsesDim() throws {
        let jid = try #require(JID.parse("alice@example.com/res"))
        let output = try #require(formatter.formatEvent(.deliveryReceiptReceived(messageID: "msg-1", from: jid), accountID: UUID()))
        #expect(output.contains("\u{001B}[2m")) // dim
    }

    @Test func messageErrorEventUsesRed() throws {
        let jid = try #require(JID.parse("alice@example.com/res"))
        let output = try #require(formatter.formatEvent(.messageError(messageID: "msg-1", from: jid, errorText: "failed"), accountID: UUID()))
        #expect(output.contains("\u{001B}[31m")) // red
    }

    // MARK: - Typing Indicator

    @Test func typingIndicatorUsesDim() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let output = try #require(formatter.formatTypingIndicator(from: jid, state: .composing))
        #expect(output.contains("\u{001B}[2m")) // dim
        #expect(output.contains("typing"))
    }
}
