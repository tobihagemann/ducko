import Foundation

public struct RosterCommandError: Error, LocalizedError, Sendable {
    public enum RemoteStatus: String, Sendable { case notSent, rejected, unconfirmed }
    public let operation: RosterCommandOutcome.Operation
    public let accountID: UUID
    public let jid: String
    public let status: RemoteStatus
    public let detail: String

    public init(operation: RosterCommandOutcome.Operation, accountID: UUID, jid: String, status: RemoteStatus, detail: String) {
        self.operation = operation
        self.accountID = accountID
        self.jid = jid
        self.status = status
        self.detail = detail
    }

    public var errorDescription: String? {
        switch status {
        case .notSent: "The contact change was not sent: \(detail)"
        case .rejected: "The server rejected the contact change: \(detail)"
        case .unconfirmed: "The contact change was not confirmed. Check the contact list before trying again: \(detail)"
        }
    }
}
