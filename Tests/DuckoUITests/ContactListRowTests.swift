import DuckoCore
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoUI

struct ContactListRowTests {
    private func contact(_ local: String, name: String? = nil, accountID: UUID = UUID()) -> Contact {
        Contact(
            id: UUID(),
            accountID: accountID,
            jid: BareJID(localPart: local, domainPart: "example.com")!,
            name: name,
            subscription: .both,
            groups: [],
            isBlocked: false,
            createdAt: Date()
        )
    }

    private func contact(jid: BareJID, accountID: UUID = UUID()) -> Contact {
        Contact(
            id: UUID(),
            accountID: accountID,
            jid: jid,
            name: nil,
            subscription: .both,
            groups: [],
            isBlocked: false,
            createdAt: Date()
        )
    }

    private func group(_ contacts: [Contact], name: String = "Friends") -> ContactGroup {
        ContactGroup(id: name, name: name, contacts: contacts)
    }

    private func room(_ local: String, name: String? = nil, accountID: UUID? = UUID()) -> Conversation {
        Conversation(
            id: UUID(),
            accountID: accountID,
            jid: BareJID(localPart: local, domainPart: "conference.example.com")!,
            type: .groupchat,
            displayName: name,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            createdAt: Date()
        )
    }

    private func build(
        groups: [ContactGroup],
        rooms: [Conversation] = [],
        expanded: Set<String> = [],
        counts: @escaping (ContactGroup) -> (online: Int, total: Int) = { ($0.contacts.count, $0.contacts.count) }
    ) -> [ContactListRow] {
        ContactListRowBuilder.rows(
            groups: groups,
            rooms: rooms,
            isGroupExpanded: { expanded.contains($0) },
            counts: counts
        )
    }

    private func isRoomsHeader(_ row: ContactListRow) -> Bool {
        if case let .header(header) = row { return header.sectionKey == roomsSectionKey }
        return false
    }

    private func isRoom(_ row: ContactListRow) -> Bool {
        if case .room = row { return true }
        return false
    }

    // MARK: - ContactListRowBuilder.rows ordering

    @Test func `expanded group emits its header then its contacts`() {
        let rows = build(groups: [group([contact("alice"), contact("bob")])], expanded: ["Friends"])
        #expect(rows.count == 3)
        guard case let .header(header) = rows[0] else { Issue.record("row 0 is not a header"); return }
        #expect(header.sectionKey == "Friends")
        #expect(header.showCount == true)
        guard case .contact = rows[1], case .contact = rows[2] else {
            Issue.record("rows 1-2 are not contacts"); return
        }
    }

    @Test func `collapsed group emits only its header`() {
        let rows = build(groups: [group([contact("alice"), contact("bob")])], expanded: [])
        #expect(rows.count == 1)
        #expect(isRoomsHeader(rows[0]) == false)
        guard case let .header(header) = rows[0] else { Issue.record("not a header"); return }
        #expect(header.sectionKey == "Friends")
    }

    @Test func `rooms section appears only when rooms exist`() {
        let g = group([contact("alice")])
        #expect(!build(groups: [g], rooms: [], expanded: ["Friends"]).contains(where: isRoomsHeader))

        let withRooms = build(groups: [g], rooms: [room("lobby")], expanded: ["Friends", roomsSectionKey])
        guard let header = withRooms.first(where: isRoomsHeader),
              case let .header(roomsHeader) = header else { Issue.record("rooms header missing"); return }
        #expect(roomsHeader.title == "Rooms")
        #expect(roomsHeader.showCount == false)
    }

    @Test func `rooms header respects its own expand state independently`() {
        let g = group([contact("alice")])
        let collapsed = build(groups: [g], rooms: [room("lobby")], expanded: ["Friends"])
        #expect(collapsed.contains(where: isRoomsHeader))
        #expect(!collapsed.contains(where: isRoom))

        let expanded = build(groups: [g], rooms: [room("lobby")], expanded: ["Friends", roomsSectionKey])
        #expect(expanded.contains(where: isRoom))
    }

    @Test func `group header carries the provided online and total counts`() {
        let rows = build(groups: [group([contact("a"), contact("b"), contact("c")])], counts: { _ in (2, 3) })
        guard case let .header(header) = rows[0] else { Issue.record("not a header"); return }
        #expect(header.online == 2)
        #expect(header.total == 3)
    }

    @Test func `headers appear in group order with the rooms section last`() {
        let groupA = group([contact("alice")], name: "A")
        let groupB = group([contact("bob")], name: "B")
        let rows = build(groups: [groupA, groupB], rooms: [room("lobby")], expanded: ["A", "B", roomsSectionKey])
        let headerKeys = rows.compactMap { row -> String? in
            if case let .header(header) = row { return header.sectionKey }
            return nil
        }
        #expect(headerKeys == ["A", "B", roomsSectionKey])
    }

    // MARK: - ContactListRow.id

    @Test func `header id is tagged and includes its section key`() {
        let row = ContactListRow.header(ContactListSectionHeader(
            sectionKey: "Friends", title: "Friends", online: 0, total: 0, showCount: true, isExpanded: true
        ))
        #expect(row.id.contains("Friends"))
    }

    @Test func `a header id never collides with a contact or room id across kinds`() {
        let accountID = UUID()
        let contactRow = ContactListRow.contact(sectionName: "Friends", contact: contact("bob", accountID: accountID))
        let roomRow = ContactListRow.room(room("lobby", accountID: accountID))
        // A hostile group named exactly like another row's encoded id must still
        // produce a distinct header id (the kind tag + re-length-prefixing).
        let headerMimickingContact = ContactListRow.header(ContactListSectionHeader(
            sectionKey: contactRow.id, title: "x", online: 0, total: 0, showCount: true, isExpanded: true
        ))
        let headerMimickingRoom = ContactListRow.header(ContactListSectionHeader(
            sectionKey: roomRow.id, title: "x", online: 0, total: 0, showCount: true, isExpanded: true
        ))
        #expect(headerMimickingContact.id != contactRow.id)
        #expect(headerMimickingRoom.id != roomRow.id)
    }

    @Test func `contact id includes its section, JID, and account`() {
        let accountID = UUID()
        let row = ContactListRow.contact(sectionName: "Friends", contact: contact("bob", accountID: accountID))
        #expect(row.id.contains("Friends"))
        #expect(row.id.contains("bob@example.com"))
        #expect(row.id.contains(accountID.uuidString))
    }

    @Test func `a same-JID contact in two sections has distinct ids`() {
        let contact = contact("bob", accountID: UUID())
        let inFriends = ContactListRow.contact(sectionName: "Friends", contact: contact)
        let inWork = ContactListRow.contact(sectionName: "Work", contact: contact)
        #expect(inFriends.id != inWork.id)
    }

    @Test func `hostile group and JID delimiters cannot forge an id collision`() throws {
        // A naive "section|jid|account" join would collide these two distinct
        // rows: "A|b" + "c@x" vs "A" + "b|c@x". `|` is valid in a JID localpart.
        let accountID = UUID()
        let jidA = try #require(BareJID(localPart: "c", domainPart: "x.example.com"))
        let jidB = try #require(BareJID(localPart: "b|c", domainPart: "x.example.com"))
        let rowA = ContactListRow.contact(sectionName: "A|b", contact: contact(jid: jidA, accountID: accountID))
        let rowB = ContactListRow.contact(sectionName: "A", contact: contact(jid: jidB, accountID: accountID))
        #expect(rowA.id != rowB.id)
    }

    @Test func `room id uses the rooms section key and distinguishes a nil account`() {
        let row = ContactListRow.room(room("lobby", accountID: nil))
        #expect(row.id.contains(roomsSectionKey))
        #expect(row.id.contains("lobby@conference.example.com"))
        #expect(row.id != ContactListRow.room(room("lobby", accountID: UUID())).id)
    }

    // MARK: - selectionKey / isSelectable

    @Test func `header is not selectable and has no selection key`() {
        let row = ContactListRow.header(ContactListSectionHeader(
            sectionKey: "g", title: "g", online: 0, total: 0, showCount: true, isExpanded: true
        ))
        #expect(row.selectionKey == nil)
        #expect(row.isSelectable == false)
    }

    @Test func `contact selection key matches its account and JID`() {
        let accountID = UUID()
        let row = ContactListRow.contact(sectionName: "Friends", contact: contact("bob", accountID: accountID))
        #expect(row.selectionKey == ConversationKey(accountID: accountID, jid: "bob@example.com"))
        #expect(row.isSelectable == true)
    }

    // MARK: - typeSelectString

    @Test func `type-select string is the contact display name`() {
        #expect(ContactListRow.contact(sectionName: "Friends", contact: contact("bob", name: "Bobby")).typeSelectString == "Bobby")
    }

    @Test func `type-select string is the room display title with a local-part fallback`() {
        #expect(ContactListRow.room(room("lobby", name: "The Lobby")).typeSelectString == "The Lobby")
        #expect(ContactListRow.room(room("lobby", name: nil)).typeSelectString == "lobby")
    }
}
