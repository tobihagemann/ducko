import AppKit
import DuckoCore
import DuckoTestSupport
import DuckoXMPP
import Foundation
import SwiftUI
import Testing
@testable import DuckoUI

@MainActor
struct ContactListOwnersTests {
    private func room(name: String = "Room") -> Conversation {
        Conversation(
            id: UUID(), accountID: UUID(), jid: BareJID(localPart: "room", domainPart: "conference.example.com")!,
            type: .groupchat, displayName: name, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
        )
    }

    private func environment() -> AppEnvironment {
        AppEnvironment(store: MockPersistenceStore(), transcripts: MockTranscriptStore(), credentialStore: NullCredentialStore())
    }

    @Test
    func `width measurement follows names theme bounds and manual width`() {
        let fixture = PreferencesFixture()
        let theme = fixture.makeThemeEngine()
        let measurement = ContactListMeasurement()
        var inputs = ContactListTableInputs(environment: environment(), theme: theme)
        inputs.maxWidthPreference = 800
        inputs.incomingRows = [.room(room(name: "Short"))]
        let short = measurement.contentWidth(inputs: inputs, manualWidth: 300)
        inputs.incomingRows = [.room(room(name: String(repeating: "W", count: 35)))]
        let wide = measurement.contentWidth(inputs: inputs, manualWidth: 300)
        #expect(wide > short)
        inputs.maxWidthPreference = 320
        #expect(measurement.contentWidth(inputs: inputs, manualWidth: 300) <= 320)
        inputs.autoSizeHorizontal = false
        #expect(measurement.contentWidth(inputs: inputs, manualWidth: 407) == 407)
        #expect(measurement.contentWidth(inputs: inputs, manualWidth: 463) == 463)
    }

    @Test
    func `height measurement invalidates for caption width theme and row count`() throws {
        let fixture = PreferencesFixture()
        let theme = fixture.makeThemeEngine()
        let environment = environment()
        let measurement = ContactListMeasurement()
        var conversation = room()
        var inputs = ContactListTableInputs(environment: environment, theme: theme, incomingRows: [.room(conversation)])
        var measures = 0
        let content: (ContactListRow) -> ContactListCellContent? = { row in
            measures += 1
            return ContactListCellContent(row: row, environment: environment, theme: theme, openChat: OpenChatAction { _, _ in }, toggle: { _ in }, showMenu: {})
        }
        let first = measurement.heights(inputs: inputs, contentWidth: 320, maxListHeight: 600, cellContent: content)
        #expect(first.newHeights.count == 1)
        #expect(first.newHeights[0] > 0)
        _ = measurement.heights(inputs: inputs, contentWidth: 320, maxListHeight: 600, cellContent: content)
        #expect(measures == 1)
        conversation.roomSubject = "A second line"
        inputs.incomingRows = [.room(conversation)]
        let caption = measurement.heights(inputs: inputs, contentWidth: 320, maxListHeight: 600, cellContent: content)
        #expect(measures == 2)
        #expect(caption.newHeights[0] >= first.newHeights[0])
        _ = measurement.heights(inputs: inputs, contentWidth: 420, maxListHeight: 600, cellContent: content)
        #expect(measures == 3)
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(theme.current)) as? [String: Any])
        encoded["avatarSize"] = theme.current.avatarSize + 12
        try theme.selectTheme(JSONDecoder().decode(DuckoTheme.self, from: JSONSerialization.data(withJSONObject: encoded)))
        _ = measurement.heights(inputs: inputs, contentWidth: 420, maxListHeight: 600, cellContent: content)
        #expect(measures == 4)
        inputs.incomingRows.append(.room(room(name: "Second room")))
        let two = measurement.heights(inputs: inputs, contentWidth: 420, maxListHeight: 600, cellContent: content)
        #expect(measures == 6)
        #expect(two.newHeights.count == 2)
    }

    @Test
    func `menu actions preserve row identity across a reorder and retain accessibility identifiers`() throws {
        let environment = environment()
        let target = NSView()
        var opened: ConversationKey?
        var sheet: ContactListRowSheet?
        let builder = ContactListMenuBuilder(
            openChat: OpenChatAction { jid, accountID in opened = ConversationKey(accountID: accountID, jid: jid) },
            openWindow: nil, transcriptScope: nil, presentSheet: { sheet = $0 }, presentNotice: { _, _ in }, target: target, action: Selector(("unused:"))
        )
        let selectedRoom = room()
        var rows: [ContactListRow] = [.room(selectedRoom), .room(room(name: "Other"))]
        let menu = try #require(builder.menu(for: rows[0], environment: environment))
        rows.reverse()
        try #require(menu.items.first?.representedObject as? MenuCommand).run()
        #expect(opened == ConversationKey(accountID: selectedRoom.accountID, jid: selectedRoom.jid.description))
        try #require(menu.items.first { $0.title == "Invite User…" }?.representedObject as? MenuCommand).run()
        if case let .invite(conversation) = sheet {
            #expect(conversation.id == selectedRoom.id)
        } else {
            Issue.record("Expected an invitation for the selected room")
        }
        let contact = try Contact(id: UUID(), accountID: UUID(), jid: #require(BareJID(localPart: "peer", domainPart: "example.com")), name: nil, subscription: .both, groups: [], isBlocked: false, createdAt: Date())
        let contactMenu = try #require(builder.menu(for: .contact(sectionName: "Friends", contact: contact), environment: environment))
        #expect(contactMenu.items.first { $0.title == "Get Info" }?.accessibilityIdentifier() == "contact-context-get-info")
        #expect(contactMenu.items.first { $0.title == "History" }?.accessibilityIdentifier() == "contact-context-history")
        #expect(contactMenu.items.allSatisfy { $0.isSeparatorItem || $0.target === target })
    }
}
