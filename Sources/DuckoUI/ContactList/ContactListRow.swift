import DuckoCore
import Foundation

/// Section key for the synthetic "Rooms" group, used as its expand/collapse key
/// and as the section prefix of its rows' diff identities.
let roomsSectionKey = "__rooms__"

/// Data for one group header row, including the `sectionKey` its toggle mutates.
struct ContactListSectionHeader {
    let sectionKey: String
    let title: String
    let online: Int
    let total: Int
    let showCount: Bool
    let isExpanded: Bool
}

/// One row the AppKit contact list renders, in body order: a header per group,
/// that group's contacts when expanded, then the Rooms header and rooms when
/// present and expanded.
enum ContactListRow {
    case header(ContactListSectionHeader)
    case contact(sectionName: String, contact: Contact)
    case room(Conversation)

    /// Section-qualified, account-qualified identity for the ordered row diff
    /// and the resize `LayoutKey`. The section prefix keeps a multi-group
    /// contact's repeated rows distinct; the account suffix keeps a same-JID
    /// peer on two accounts distinct. Independent of the visible
    /// `contact-row-*` accessibility identifier, which only account-qualifies
    /// when the JID is actually duplicated.
    ///
    /// Every kind is tagged (`h`/`c`/`r`) and length-prefixed rather than
    /// delimiter-joined: a roster group name and a JID localpart are both
    /// server-controlled and may contain any delimiter character (`|` is valid
    /// in a JID localpart), so a plain join could let a hostile server forge a
    /// collision — between two contacts, or between a group header and an
    /// encoded contact/room id. The kind tag plus length-prefixing makes every
    /// row id unambiguous across kinds.
    var id: String {
        switch self {
        case let .header(header):
            return Self.qualifiedID("h", header.sectionKey)
        case let .contact(sectionName, contact):
            return Self.qualifiedID("c", sectionName, contact.jid.description, contact.accountID.uuidString)
        case let .room(room):
            return Self.qualifiedID("r", roomsSectionKey, room.jid.description, room.accountID?.uuidString ?? "-")
        }
    }

    /// Joins identity components length-prefixed (`<utf8-count>:<component>`) so
    /// an embedded delimiter in any single component can't shift the boundary
    /// and collide with a different split of the same characters.
    private static func qualifiedID(_ components: String...) -> String {
        components.map { "\($0.utf8.count):\($0)" }.joined()
    }

    /// Selection/open identity, independent of which section row was clicked so
    /// double-click and Return open the same chat regardless of section. `nil`
    /// for headers, which are non-selectable.
    var selectionKey: ConversationKey? {
        switch self {
        case .header:
            return nil
        case let .contact(_, contact):
            return ConversationKey(accountID: contact.accountID, jid: contact.jid.description)
        case let .room(room):
            return ConversationKey(accountID: room.accountID, jid: room.jid.description)
        }
    }

    /// The string keyboard type-select matches against — the same text the row
    /// renders, never the account-label suffix, so typing a letter jumps to
    /// what the user sees for a renamed contact. `nil` for headers.
    var typeSelectString: String? {
        switch self {
        case .header:
            return nil
        case let .contact(_, contact):
            return contact.displayName
        case let .room(room):
            return room.displayTitle
        }
    }

    var isSelectable: Bool {
        selectionKey != nil
    }
}

/// Pure builder for the ordered `[ContactListRow]` the table renders, in body
/// order: group header, that group's contacts when expanded, then the Rooms
/// header and rooms when present and expanded. Row construction and height
/// measurement share this one ordering.
enum ContactListRowBuilder {
    static func rows(
        groups: [ContactGroup],
        rooms: [Conversation],
        isGroupExpanded: (String) -> Bool,
        counts: (ContactGroup) -> (online: Int, total: Int)
    ) -> [ContactListRow] {
        var rows: [ContactListRow] = []
        for group in groups {
            let groupCounts = counts(group)
            rows.append(.header(ContactListSectionHeader(
                sectionKey: group.name,
                title: group.name,
                online: groupCounts.online,
                total: groupCounts.total,
                showCount: true,
                isExpanded: isGroupExpanded(group.name)
            )))
            if isGroupExpanded(group.name) {
                rows.append(contentsOf: group.contacts.map { .contact(sectionName: group.name, contact: $0) })
            }
        }
        if !rooms.isEmpty {
            rows.append(.header(ContactListSectionHeader(
                sectionKey: roomsSectionKey,
                title: "Rooms",
                online: 0,
                total: 0,
                showCount: false,
                isExpanded: isGroupExpanded(roomsSectionKey)
            )))
            if isGroupExpanded(roomsSectionKey) {
                rows.append(contentsOf: rooms.map { .room($0) })
            }
        }
        return rows
    }
}
