import DuckoCore
import Foundation

extension MessageRecord {
    func toDomain() -> ChatMessage? {
        guard let conversationID = conversation?.id else { return nil }
        return ChatMessage(
            id: id,
            conversationID: conversationID,
            stanzaID: stanzaID,
            serverID: serverID,
            fromJID: fromJID,
            body: body,
            htmlBody: htmlBody,
            timestamp: timestamp,
            isOutgoing: isOutgoing,
            isRead: isRead,
            isDelivered: isDelivered,
            isEdited: isEdited,
            editedAt: editedAt,
            type: type,
            replyToID: replyToID,
            errorText: errorText,
            isRetracted: isRetracted,
            retractedAt: retractedAt,
            isEncrypted: isEncrypted,
            attachments: attachments.map { $0.toDomain() }
        )
    }
}
