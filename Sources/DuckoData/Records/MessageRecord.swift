import Foundation
import SwiftData

@Model
final class MessageRecord {
    @Attribute(.unique) var id: UUID
    var stanzaID: String?
    var serverID: String?
    var fromJID: String
    var body: String
    var htmlBody: String?
    var timestamp: Date
    var isOutgoing: Bool
    var isRead: Bool
    var isDelivered: Bool
    var isEdited: Bool
    var editedAt: Date?
    var type: String
    var conversation: ConversationRecord?
    @Relationship(deleteRule: .cascade, inverse: \AttachmentRecord.message)
    var attachments: [AttachmentRecord]
    var replyToID: String?
    var errorText: String?

    init(
        id: UUID,
        stanzaID: String? = nil,
        serverID: String? = nil,
        fromJID: String,
        body: String,
        htmlBody: String? = nil,
        timestamp: Date = Date(),
        isOutgoing: Bool = false,
        isRead: Bool = false,
        isDelivered: Bool = false,
        isEdited: Bool = false,
        editedAt: Date? = nil,
        type: String = "chat",
        conversation: ConversationRecord? = nil,
        attachments: [AttachmentRecord] = [],
        replyToID: String? = nil,
        errorText: String? = nil
    ) {
        self.id = id
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
        self.conversation = conversation
        self.attachments = attachments
        self.replyToID = replyToID
        self.errorText = errorText
    }
}
