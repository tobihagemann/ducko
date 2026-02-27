import DuckoCore
import DuckoXMPP
import Foundation

protocol CLIFormatter: Sendable {
    func formatMessage(_ message: ChatMessage) -> String
    func formatContact(_ contact: Contact) -> String
    func formatPresence(jid: BareJID, status: String, message: String?) -> String
    func formatError(_ error: any Error) -> String
    func formatEvent(_ event: XMPPEvent, accountID: UUID) -> String?
    func formatConnectionState(_ state: AccountService.ConnectionState, jid: BareJID) -> String
}

func iso8601(_ date: Date) -> String {
    date.formatted(
        Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    )
}
