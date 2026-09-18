import Foundation

public struct RosterCommandOutcome: Sendable {
    public enum Operation: String, Sendable { case add, remove }
    public enum LocalStatus: String, Sendable { case synchronized, incomplete, different }
    public enum SubscriptionStatus: String, Sendable { case notRequested, sent, incomplete }

    public let operation: Operation
    public let accountID: UUID
    public let jid: String
    public let localStatus: LocalStatus
    public let subscriptionStatus: SubscriptionStatus

    public var isComplete: Bool {
        localStatus == .synchronized && subscriptionStatus != .incomplete
    }

    public init(operation: Operation, accountID: UUID, jid: String, localStatus: LocalStatus, subscriptionStatus: SubscriptionStatus) {
        self.operation = operation
        self.accountID = accountID
        self.jid = jid
        self.localStatus = localStatus
        self.subscriptionStatus = subscriptionStatus
    }

    public var message: String {
        let action = operation == .add ? "adding" : "removing"
        switch localStatus {
        case .incomplete:
            return "The server confirmed \(action) \(jid), but contacts did not finish syncing. Reconnect to check the contact list before making another change."
        case .different:
            return "The server confirmed \(action) \(jid), but the current contact list differs from the request. Check the contact list before making another change."
        case .synchronized:
            if subscriptionStatus == .incomplete {
                return "Added \(jid) to contacts, but the presence request was not confirmed as sent. You can request presence separately."
            }
            return operation == .add ? "Added \(jid) to contacts. Presence requested." : "Removed \(jid) from contacts."
        }
    }
}
