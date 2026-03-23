import Foundation

public struct TranscriptAmendment: Sendable {
    public enum Action: String, Sendable, Codable {
        case edit, retract, delivery, error
    }

    public var action: Action
    public var targetStanzaID: String?
    public var targetServerID: String?
    public var timestamp: Date
    public var body: String?
    public var htmlBody: String?
    public var errorText: String?

    public init(
        action: Action,
        targetStanzaID: String? = nil,
        targetServerID: String? = nil,
        timestamp: Date = Date(),
        body: String? = nil,
        htmlBody: String? = nil,
        errorText: String? = nil
    ) {
        self.action = action
        self.targetStanzaID = targetStanzaID
        self.targetServerID = targetServerID
        self.timestamp = timestamp
        self.body = body
        self.htmlBody = htmlBody
        self.errorText = errorText
    }
}
