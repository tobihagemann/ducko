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

    // MARK: - fittedHeight

    @Test func `fittedHeight returns the fallback when nothing has been measured`() {
        // Measured 0 → fall back to the estimate (120), which is below the cap.
        #expect(ContactListSizing.fittedHeight(measuredHeight: 0, fallbackHeight: 120, maxHeight: 600) == 120)
    }

    @Test func `fittedHeight returns the fallback for a non-finite measurement`() {
        #expect(ContactListSizing.fittedHeight(measuredHeight: .nan, fallbackHeight: 120, maxHeight: 600) == 120)
        #expect(ContactListSizing.fittedHeight(measuredHeight: .infinity, fallbackHeight: 120, maxHeight: 600) == 120)
    }

    @Test func `fittedHeight rounds a fractional measurement up`() {
        // 123.2 rounds up to 124, within the cap.
        #expect(ContactListSizing.fittedHeight(measuredHeight: 123.2, fallbackHeight: 80, maxHeight: 600) == 124)
    }

    @Test func `fittedHeight caps a measurement above the maximum`() {
        // 900 measured, clamped down to 600.
        #expect(ContactListSizing.fittedHeight(measuredHeight: 900, fallbackHeight: 80, maxHeight: 600) == 600)
    }

    @Test func `fittedHeight caps the fallback at the maximum`() {
        // Unmeasured, but the estimate (900) exceeds the cap, so it clamps to 600.
        #expect(ContactListSizing.fittedHeight(measuredHeight: 0, fallbackHeight: 900, maxHeight: 600) == 600)
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
