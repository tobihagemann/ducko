import DuckoCore
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCLI

struct PlainFormatterTests {
    let formatter = PlainFormatter()

    // MARK: - formatMessage

    @Test func formatMessageIncoming() {
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
        #expect(output.contains("<-"))
        #expect(output.contains("alice@example.com"))
        #expect(output.contains("Hello!"))
    }

    @Test func formatMessageOutgoing() {
        let message = ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: "bob@example.com",
            body: "Hi there",
            timestamp: Date(),
            isOutgoing: true,
            isRead: true,
            isDelivered: false,
            isEdited: false,
            type: "chat"
        )
        let output = formatter.formatMessage(message)
        #expect(output.contains("->"))
        #expect(output.contains("bob@example.com"))
        #expect(output.contains("Hi there"))
    }

    // MARK: - formatContact

    @Test func formatContactWithName() throws {
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
        let output = formatter.formatContact(contact)
        #expect(output.contains("Alice"))
        #expect(output.contains("alice@example.com"))
        #expect(output.contains("[both]"))
    }

    @Test func formatContactWithoutName() throws {
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
        let output = formatter.formatContact(contact)
        #expect(output.contains("bob@example.com"))
        #expect(output.contains("[to]"))
    }

    // MARK: - formatAccount

    @Test func formatAccount() throws {
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
        #expect(output.contains("alice@example.com"))
        #expect(output.contains(accountID.uuidString))
    }

    // MARK: - formatContactWithPresence

    @Test func formatContactWithPresenceAvailable() throws {
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
        #expect(output.contains("[+]"))
        #expect(output.contains("Alice"))
        #expect(output.contains("alice@example.com"))
        #expect(output.contains("[both]"))
    }

    @Test func formatContactWithPresenceAway() throws {
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
        #expect(output.contains("[~]"))
    }

    @Test func formatContactWithPresenceDND() throws {
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
        #expect(output.contains("[-]"))
    }

    @Test func formatContactWithPresenceOffline() throws {
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
        #expect(output.contains("[ ]"))
    }

    @Test func formatContactWithPresenceUsesLocalAlias() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let contact = Contact(
            id: UUID(),
            accountID: UUID(),
            jid: jid,
            name: "Alice",
            localAlias: "Ally",
            subscription: .both,
            groups: [],
            isBlocked: false,
            createdAt: Date()
        )
        let output = formatter.formatContactWithPresence(contact, presence: .available)
        #expect(output.contains("Ally"))
        #expect(!output.hasPrefix("[+] Alice"))
    }

    // MARK: - formatGroupHeader

    @Test func formatGroupHeader() throws {
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
        #expect(output.contains("Friends"))
        #expect(output.contains("3"))
    }

    // MARK: - formatPresence

    @Test func formatPresenceWithMessage() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let output = formatter.formatPresence(jid: jid, status: "away", message: "Gone fishing")
        #expect(output.contains("alice@example.com"))
        #expect(output.contains("away"))
        #expect(output.contains("Gone fishing"))
    }

    @Test func formatPresenceWithoutMessage() throws {
        let jid = try #require(BareJID.parse("alice@example.com"))
        let output = formatter.formatPresence(jid: jid, status: "available", message: nil)
        #expect(output.contains("alice@example.com"))
        #expect(output.contains("available"))
    }

    // MARK: - formatError

    @Test func formatError() {
        let output = formatter.formatError(CLIError.noAccounts)
        #expect(output.hasPrefix("error:"))
    }

    // MARK: - formatEvent

    @Test func formatEventConnected() throws {
        let jid = try #require(FullJID.parse("alice@example.com/res"))
        let output = try #require(formatter.formatEvent(.connected(jid), accountID: UUID()))
        #expect(output.contains("connected"))
    }

    @Test func formatEventDisconnected() throws {
        let output = try #require(formatter.formatEvent(.disconnected(.requested), accountID: UUID()))
        #expect(output.contains("disconnected"))
    }

    @Test func formatEventIQReturnsNil() {
        let iq = XMPPIQ(type: .result)
        let output = formatter.formatEvent(.iqReceived(iq), accountID: UUID())
        #expect(output == nil)
    }
}
