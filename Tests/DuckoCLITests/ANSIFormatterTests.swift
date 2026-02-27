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
}
