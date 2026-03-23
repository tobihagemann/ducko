import Foundation

/// Human-readable metadata stored as `meta.json` alongside transcript files.
public struct TranscriptMetadata: Sendable, Codable {
    public var conversationID: UUID
    public var accountJID: String
    public var contactJID: String
    public var type: String
    public var displayName: String?
    public var occupantNickname: String?

    public init(
        conversationID: UUID,
        accountJID: String,
        contactJID: String,
        type: String,
        displayName: String? = nil,
        occupantNickname: String? = nil
    ) {
        self.conversationID = conversationID
        self.accountJID = accountJID
        self.contactJID = contactJID
        self.type = type
        self.displayName = displayName
        self.occupantNickname = occupantNickname
    }
}
