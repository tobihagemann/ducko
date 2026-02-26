import Foundation
import DuckoCore

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
            errorText: errorText
        )
    }

    func update(from message: ChatMessage) {
        stanzaID = message.stanzaID
        serverID = message.serverID
        fromJID = message.fromJID
        body = message.body
        htmlBody = message.htmlBody
        timestamp = message.timestamp
        isOutgoing = message.isOutgoing
        isRead = message.isRead
        isDelivered = message.isDelivered
        isEdited = message.isEdited
        editedAt = message.editedAt
        type = message.type
        replyToID = message.replyToID
        errorText = message.errorText
    }
}
