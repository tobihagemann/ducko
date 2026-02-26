import Foundation
import SwiftData

@Model
final class ConversationRecord {
    @Attribute(.unique) var id: UUID
    var jid: String
    var type: String
    var displayName: String?
    var isPinned: Bool
    var isMuted: Bool
    var lastMessageDate: Date?
    var lastMessagePreview: String?
    var unreadCount: Int
    var account: AccountRecord?
    @Relationship(deleteRule: .cascade, inverse: \MessageRecord.conversation)
    var messages: [MessageRecord]
    var roomSubject: String?
    var roomNickname: String?
    var createdAt: Date

    init(
        id: UUID,
        jid: String,
        type: String = "chat",
        displayName: String? = nil,
        isPinned: Bool = false,
        isMuted: Bool = false,
        lastMessageDate: Date? = nil,
        lastMessagePreview: String? = nil,
        unreadCount: Int = 0,
        account: AccountRecord? = nil,
        messages: [MessageRecord] = [],
        roomSubject: String? = nil,
        roomNickname: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.jid = jid
        self.type = type
        self.displayName = displayName
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.lastMessageDate = lastMessageDate
        self.lastMessagePreview = lastMessagePreview
        self.unreadCount = unreadCount
        self.account = account
        self.messages = messages
        self.roomSubject = roomSubject
        self.roomNickname = roomNickname
        self.createdAt = createdAt
    }
}
