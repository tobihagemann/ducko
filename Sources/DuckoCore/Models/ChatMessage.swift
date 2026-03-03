import Foundation

public struct ChatMessage: Sendable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    public var stanzaID: String?
    public var serverID: String?
    public var fromJID: String
    public var body: String
    public var htmlBody: String?
    public var timestamp: Date
    public var isOutgoing: Bool
    public var isRead: Bool
    public var isDelivered: Bool
    public var isEdited: Bool
    public var editedAt: Date?
    public var type: String
    public var replyToID: String?
    public var errorText: String?
    public var attachments: [Attachment]

    public init(
        id: UUID,
        conversationID: UUID,
        stanzaID: String? = nil,
        serverID: String? = nil,
        fromJID: String,
        body: String,
        htmlBody: String? = nil,
        timestamp: Date,
        isOutgoing: Bool,
        isRead: Bool,
        isDelivered: Bool,
        isEdited: Bool,
        editedAt: Date? = nil,
        type: String,
        replyToID: String? = nil,
        errorText: String? = nil,
        attachments: [Attachment] = []
    ) {
        self.id = id
        self.conversationID = conversationID
        self.stanzaID = stanzaID
        self.serverID = serverID
        self.fromJID = fromJID
        self.body = body
        self.htmlBody = htmlBody
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.isRead = isRead
        self.isDelivered = isDelivered
        self.isEdited = isEdited
        self.editedAt = editedAt
        self.type = type
        self.replyToID = replyToID
        self.errorText = errorText
        self.attachments = attachments
    }
}
