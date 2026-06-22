import DuckoCore

/// A sheet a contact-list row's context menu can present. The AppKit context
/// menu (owned by `NSTableView` so it draws the native row emphasis) routes
/// these up to `ContactListView`, which owns the `.sheet(item:)`.
enum ContactListRowSheet: Identifiable {
    case rename(Contact)
    case invite(Conversation)
    case roomSettings(Conversation)

    var id: String {
        switch self {
        case let .rename(contact): "rename-\(contact.id)"
        case let .invite(conversation): "invite-\(conversation.id)"
        case let .roomSettings(conversation): "room-settings-\(conversation.id)"
        }
    }
}
