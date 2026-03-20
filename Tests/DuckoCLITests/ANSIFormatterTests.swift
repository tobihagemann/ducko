import DuckoCore
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCLI

struct ANSIFormatterTests {
    let formatter = ANSIFormatter()

    @Test func `output contains ANSI escape codes`() {
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

    @Test func `account uses bold and dim`() throws {
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

    @Test func `error uses red code`() {
        let output = formatter.formatError(CLIError.connectionTimeout)
        #expect(output.contains("\u{001B}[31m"))
    }

    @Test func `incoming message uses green`() {
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

    @Test func `contact available uses green`() throws {
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

    @Test func `contact away uses yellow`() throws {
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

    @Test func `contact DND uses red`() throws {
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

    @Test func `contact offline uses dim`() throws {
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

    @Test func `subscription request uses yellow`() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let output = try #require(formatter.formatEvent(.presenceSubscriptionRequest(from: jid), accountID: UUID()))
        #expect(output.contains("\u{001B}[33m")) // yellow
        #expect(output.contains("alice@example.com"))
        #expect(output.contains("/approve"))
    }

    @Test func `outgoing message uses cyan`() {
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

    @Test func `delivered shows checkmark`() {
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

    @Test func `edited shows dim marker`() {
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

    @Test func `delivery receipt event uses dim`() throws {
        let jid = try #require(JID.parse("alice@example.com/res"))
        let output = try #require(formatter.formatEvent(.deliveryReceiptReceived(messageID: "msg-1", from: jid), accountID: UUID()))
        #expect(output.contains("\u{001B}[2m")) // dim
    }

    @Test func `message error event uses red`() throws {
        let jid = try #require(JID.parse("alice@example.com/res"))
        let error = XMPPStanzaError(errorType: .cancel, condition: .serviceUnavailable, text: "failed")
        let output = try #require(formatter.formatEvent(.messageError(messageID: "msg-1", from: jid, error: error), accountID: UUID()))
        #expect(output.contains("\u{001B}[31m")) // red
    }

    // MARK: - Attachments

    @Test func `message with attachments includes file info`() {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "alice@example.com",
            body: "Check this out",
            timestamp: Date(),
            isOutgoing: false,
            isRead: false,
            isDelivered: false,
            isEdited: false,
            type: "chat",
            attachments: [Attachment(id: UUID(), url: "https://example.com/photo.jpg", fileName: "photo.jpg")]
        )
        let output = formatter.formatMessage(message)
        #expect(output.contains("https://example.com/photo.jpg"))
        #expect(output.contains("photo.jpg"))
    }

    @Test func `message without attachments has no file info`() {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "alice@example.com",
            body: "Just text",
            timestamp: Date(),
            isOutgoing: false,
            isRead: false,
            isDelivered: false,
            isEdited: false,
            type: "chat"
        )
        let output = formatter.formatMessage(message)
        #expect(!output.contains("File:"))
        #expect(!output.contains("\u{1F4CE}"))
    }

    // MARK: - Typing Indicator

    @Test func `typing indicator uses dim`() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let output = try #require(formatter.formatTypingIndicator(from: jid, state: .composing))
        #expect(output.contains("\u{001B}[2m")) // dim
        #expect(output.contains("typing"))
    }

    // MARK: - formatRegistrationForm

    @Test func `format legacy registration form with ANSI codes`() {
        let form = RegistrationFormInfo(from: RegistrationModule.RegistrationForm(
            formType: .legacy,
            instructions: "Register here",
            isRegistered: false,
            hasUsername: true,
            hasPassword: true,
            hasEmail: false,
            dataFormFields: []
        ))
        let output = formatter.formatRegistrationForm(form)
        #expect(output.contains("\u{001B}[1m")) // bold
        #expect(output.contains("Legacy"))
        #expect(output.contains("Not registered"))
        #expect(output.contains("Username"))
        #expect(output.contains("Password"))
        #expect(!output.contains("Email"))
    }

    @Test func `format data form registration with ANSI codes`() {
        let form = RegistrationFormInfo(from: RegistrationModule.RegistrationForm(
            formType: .dataForm,
            instructions: nil,
            isRegistered: true,
            hasUsername: false,
            hasPassword: false,
            hasEmail: false,
            dataFormFields: [
                DataFormField(variable: "nick", type: "text-single", label: "Nickname", values: ["bob"])
            ]
        ))
        let output = formatter.formatRegistrationForm(form)
        #expect(output.contains("\u{001B}[36m")) // cyan for field labels
        #expect(output.contains("Data Form"))
        #expect(output.contains("Nickname"))
        #expect(output.contains("bob"))
    }
}
