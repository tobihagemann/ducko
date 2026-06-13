import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCore

private let sizingAccountID = UUID()
private let sizingJID1 = BareJID(localPart: "alice", domainPart: "example.com")!
private let sizingJID2 = BareJID(localPart: "bob", domainPart: "example.com")!
private let sizingJID3 = BareJID(localPart: "carol", domainPart: "example.com")!

private func makeContact(_ jid: BareJID) -> Contact {
    Contact(
        id: UUID(),
        accountID: sizingAccountID,
        jid: jid,
        subscription: .both,
        groups: [],
        isBlocked: false,
        createdAt: Date()
    )
}

struct ContactListSizingTests {
    // MARK: - clampMaxWidth

    @Test func `clampMaxWidth passes an in-range value through`() {
        #expect(ContactListSizing.clampMaxWidth(280) == 280)
    }

    @Test func `clampMaxWidth raises a sub-minimum value to the slider minimum`() {
        #expect(ContactListSizing.clampMaxWidth(0) == ContactListSizingDefaults.sliderMinWidth)
        #expect(ContactListSizing.clampMaxWidth(-50) == ContactListSizingDefaults.sliderMinWidth)
    }

    @Test func `clampMaxWidth lowers an above-maximum value to the slider maximum`() {
        #expect(ContactListSizing.clampMaxWidth(10000) == ContactListSizingDefaults.sliderMaxWidth)
    }

    @Test func `clampMaxWidth substitutes the default for a non-finite value`() {
        #expect(ContactListSizing.clampMaxWidth(.nan) == ContactListSizingDefaults.defaultMaxWidth)
        #expect(ContactListSizing.clampMaxWidth(.infinity) == ContactListSizingDefaults.defaultMaxWidth)
    }

    // MARK: - fittedWidth

    @Test func `fittedWidth returns the floor when nothing has been measured`() {
        let width = ContactListSizing.fittedWidth(
            maxNameWidth: 0, avatarSize: 40, rowChrome: 70, floorWidth: 200, maxWidth: 280
        )
        #expect(width == 200)
    }

    @Test func `fittedWidth caps the floor at maxWidth when maxWidth is below it`() {
        let width = ContactListSizing.fittedWidth(
            maxNameWidth: 0, avatarSize: 40, rowChrome: 70, floorWidth: 200, maxWidth: 150
        )
        #expect(width == 150)
    }

    @Test func `fittedWidth fits the measured name plus chrome`() {
        // 100 + 40 + 70 = 210, within [200, 280].
        let width = ContactListSizing.fittedWidth(
            maxNameWidth: 100, avatarSize: 40, rowChrome: 70, floorWidth: 200, maxWidth: 280
        )
        #expect(width == 210)
    }

    @Test func `fittedWidth raises a narrow measurement to the floor`() {
        // 10 + 40 + 70 = 120, raised to the floor 200.
        let width = ContactListSizing.fittedWidth(
            maxNameWidth: 10, avatarSize: 40, rowChrome: 70, floorWidth: 200, maxWidth: 280
        )
        #expect(width == 200)
    }

    @Test func `fittedWidth caps the result at maxWidth`() {
        // 300 + 40 + 70 = 410, clamped down to 280.
        let width = ContactListSizing.fittedWidth(
            maxNameWidth: 300, avatarSize: 40, rowChrome: 70, floorWidth: 200, maxWidth: 280
        )
        #expect(width == 280)
    }

    // MARK: - listContentHeight

    @Test func `listContentHeight sums headers and only expanded contacts`() {
        // Group 1: header + 3 rows; group 2: header only (collapsed).
        let height = ContactListSizing.listContentHeight(
            groups: [(contactCount: 3, isExpanded: true), (contactCount: 5, isExpanded: false)],
            roomCount: 0,
            roomsExpanded: false,
            groupRowHeight: 24,
            rowHeight: 50
        )
        // Group 1: header (24) + 3 rows (50). Group 2: header only (24).
        let expected: Double = 198
        #expect(height == expected)
    }

    @Test func `listContentHeight adds the rooms section only when rooms exist`() {
        let withoutRooms = ContactListSizing.listContentHeight(
            groups: [(contactCount: 2, isExpanded: true)],
            roomCount: 0, roomsExpanded: true,
            groupRowHeight: 24, rowHeight: 50
        )
        // One group header (24) + 2 contacts (50 each).
        let contactsSectionHeight: Double = 124
        #expect(withoutRooms == contactsSectionHeight)

        let withRooms = ContactListSizing.listContentHeight(
            groups: [(contactCount: 2, isExpanded: true)],
            roomCount: 2, roomsExpanded: true,
            groupRowHeight: 24, rowHeight: 50
        )
        // Plus a rooms header (24) + 2 rooms (50 each).
        let roomsSectionHeight: Double = 124
        #expect(withRooms == contactsSectionHeight + roomsSectionHeight)
    }

    @Test func `listContentHeight keeps a collapsed rooms header but drops its rows`() {
        let height = ContactListSizing.listContentHeight(
            groups: [],
            roomCount: 3, roomsExpanded: false,
            groupRowHeight: 24, rowHeight: 50
        )
        #expect(height == 24)
    }

    // MARK: - onlineCounts

    @Test func `onlineCounts counts the total against the unfiltered roster`() {
        // Displayed set is filtered down to one; the unfiltered roster has three.
        let displayed = [makeContact(sizingJID1)]
        let unfiltered = [ContactGroup(
            id: "friends",
            name: "Friends",
            contacts: [makeContact(sizingJID1), makeContact(sizingJID2), makeContact(sizingJID3)]
        )]
        let online: Set<BareJID> = [sizingJID1, sizingJID2]

        let counts = ContactListSizing.onlineCounts(
            groupID: "friends",
            unfilteredRoster: unfiltered,
            displayedContacts: displayed
        ) { online.contains($0.jid) }

        #expect(counts.online == 2)
        #expect(counts.total == 3)
    }

    @Test func `onlineCounts falls back to displayed contacts when the group is absent`() {
        let displayed = [makeContact(sizingJID1), makeContact(sizingJID2)]

        let counts = ContactListSizing.onlineCounts(
            groupID: "missing",
            unfilteredRoster: [],
            displayedContacts: displayed
        ) { _ in true }

        #expect(counts.online == 2)
        #expect(counts.total == 2)
    }
}
