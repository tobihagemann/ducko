import DuckoCore
import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoUI

@MainActor
struct ContactListWindowStateTests {
    @Test func `toggleSearch reveals the search field`() {
        let state = ContactListWindowState()
        #expect(state.isSearching == false)

        state.toggleSearch()

        #expect(state.isSearching == true)
    }

    @Test func `toggleSearch off clears the query`() {
        let state = ContactListWindowState()
        state.toggleSearch()
        state.searchText = "alice"

        state.toggleSearch()

        #expect(state.isSearching == false)
        #expect(state.searchText == "")
    }

    @Test func `endSearch resets both the flag and the query`() {
        let state = ContactListWindowState()
        state.isSearching = true
        state.searchText = "bob"

        state.endSearch()

        #expect(state.isSearching == false)
        #expect(state.searchText == "")
    }

    // MARK: - Contact Commands

    private struct Fixture {
        let environment: AppEnvironment
        let contact: Contact
        let room: Conversation
    }

    private static func makeFixture() async throws -> Fixture {
        let store = MockPersistenceStore()
        let account = try Account(id: UUID(), jid: #require(BareJID.parse("alice@example.com")), isEnabled: true, connectOnLaunch: false, createdAt: Date())
        await store.addAccount(account)
        let contact = try Contact(
            id: UUID(), accountID: account.id, jid: #require(BareJID.parse("bob@example.com")),
            name: "Bob", subscription: .both, groups: [], isBlocked: false, createdAt: Date()
        )
        try await store.upsertContact(contact)
        let room = try Conversation(
            id: UUID(), accountID: account.id, jid: #require(BareJID.parse("room@conference.example.com")),
            type: .groupchat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
        )
        let environment = AppEnvironment(store: store, transcripts: MockTranscriptStore(), credentialStore: NullCredentialStore())
        try await environment.accountService.loadAccounts()
        try await environment.rosterService.loadContacts(for: account.id)
        return Fixture(environment: environment, contact: contact, room: room)
    }

    private static let header = ContactListRow.header(ContactListSectionHeader(
        sectionKey: "Friends", title: "Friends", online: 0, total: 0, showCount: true, isExpanded: true
    ))

    @Test func `a contact row targets the contact`() async throws {
        let fixture = try await Self.makeFixture()
        let state = ContactListWindowState()
        state.selectedRow = .contact(sectionName: "Friends", contact: fixture.contact)

        let target = try #require(state.commandTarget(in: fixture.environment))

        #expect(target.contactInfoRef == ContactInfoRef(accountID: fixture.contact.accountID, jid: "bob@example.com"))
        #expect(target.transcriptRef == ConversationRef(accountID: fixture.contact.accountID, jid: "bob@example.com", type: .chat))
        #expect(target.chatKey == ConversationKey(accountID: fixture.contact.accountID, jid: "bob@example.com"))
        #expect(target.contact?.id == fixture.contact.id)
    }

    @Test func `a contact row targets the live roster contact over the row snapshot`() async throws {
        let fixture = try await Self.makeFixture()
        let state = ContactListWindowState()
        let staleSnapshot = Contact(
            id: fixture.contact.id, accountID: fixture.contact.accountID, jid: fixture.contact.jid,
            name: "Old Bob", subscription: .both, groups: [], isBlocked: false, createdAt: fixture.contact.createdAt
        )
        state.selectedRow = .contact(sectionName: "Friends", contact: staleSnapshot)

        state.removeSelectedContact(in: fixture.environment)

        #expect(state.commandTarget(in: fixture.environment)?.contact?.name == "Bob")
        #expect(state.pendingRemoval?.name == "Bob")
    }

    @Test func `a contact row missing from the roster has no target`() async throws {
        let fixture = try await Self.makeFixture()
        let state = ContactListWindowState()
        let removed = try Contact(
            id: UUID(), accountID: fixture.contact.accountID, jid: #require(BareJID.parse("carol@example.com")),
            name: "Carol", subscription: .both, groups: [], isBlocked: false, createdAt: Date()
        )
        state.selectedRow = .contact(sectionName: "Friends", contact: removed)

        state.removeSelectedContact(in: fixture.environment)

        #expect(state.commandTarget(in: fixture.environment) == nil)
        #expect(state.pendingRemoval == nil)
    }

    @Test func `a contact row scopes history to its own account's open conversation`() async throws {
        let store = MockPersistenceStore()
        let account = try Account(id: UUID(), jid: #require(BareJID.parse("alice@example.com")), isEnabled: true, connectOnLaunch: false, createdAt: Date())
        let other = try Account(id: UUID(), jid: #require(BareJID.parse("alice@other.example")), isEnabled: true, connectOnLaunch: false, createdAt: Date())
        await store.addAccount(account)
        await store.addAccount(other)
        let bobJID = try #require(BareJID.parse("bob@example.com"))
        let contact = Contact(id: UUID(), accountID: account.id, jid: bobJID, name: "Bob", subscription: .both, groups: [], isBlocked: false, createdAt: Date())
        try await store.upsertContact(contact)
        // The same peer is open on both accounts; the other account's newer conversation sorts first.
        let otherConversation = Conversation(
            id: UUID(), accountID: other.id, jid: bobJID, type: .chat, isPinned: false, isMuted: false,
            lastMessageDate: Date(), unreadCount: 0, createdAt: Date()
        )
        let ownConversation = Conversation(
            id: UUID(), accountID: account.id, jid: bobJID, type: .chat, isPinned: false, isMuted: false,
            lastMessageDate: Date(timeIntervalSinceNow: -3600), unreadCount: 0, createdAt: Date()
        )
        await store.addConversation(otherConversation)
        await store.addConversation(ownConversation)
        let environment = AppEnvironment(store: store, transcripts: MockTranscriptStore(), credentialStore: NullCredentialStore())
        try await environment.accountService.loadAccounts()
        try await environment.rosterService.loadContacts(for: account.id)
        try await environment.chatService.loadConversations(for: other.id)
        try await environment.chatService.loadConversations(for: account.id)
        let state = ContactListWindowState()
        state.selectedRow = .contact(sectionName: "Friends", contact: contact)

        let target = try #require(state.commandTarget(in: environment))

        #expect(target.transcriptRef.conversationID == ownConversation.id)
    }

    @Test func `a room row targets the room without contact info`() async throws {
        let fixture = try await Self.makeFixture()
        let state = ContactListWindowState()
        state.selectedRow = .room(fixture.room)

        let target = try #require(state.commandTarget(in: fixture.environment))

        #expect(target.contactInfoRef == nil)
        #expect(target.transcriptRef == ConversationRef(conversation: fixture.room))
        #expect(target.contact == nil)
    }

    @Test func `a header row or no selection has no target`() async throws {
        let fixture = try await Self.makeFixture()
        let state = ContactListWindowState()
        #expect(state.commandTarget(in: fixture.environment) == nil)

        state.selectedRow = Self.header

        #expect(state.commandTarget(in: fixture.environment) == nil)
    }

    @Test func `removeSelectedContact asks to confirm the selected contact`() async throws {
        let fixture = try await Self.makeFixture()
        let state = ContactListWindowState()
        state.selectedRow = .contact(sectionName: "Friends", contact: fixture.contact)
        #expect(state.canRemoveSelectedContact)

        state.removeSelectedContact(in: fixture.environment)

        #expect(state.pendingRemoval?.id == fixture.contact.id)
    }

    @Test func `removal is unavailable without a selected contact`() async throws {
        let fixture = try await Self.makeFixture()
        let state = ContactListWindowState()
        #expect(!state.canRemoveSelectedContact)

        state.selectedRow = .room(fixture.room)
        #expect(!state.canRemoveSelectedContact)

        state.selectedRow = Self.header
        #expect(!state.canRemoveSelectedContact)
    }

    enum RemovalBlocker: CaseIterable {
        case search, inviteNickname, addContact, joinRoom, bookmarks, profile, customStatus, rowSheet, pendingRemoval
    }

    @Test(arguments: RemovalBlocker.allCases)
    func `removal is unavailable while search or a sheet is up`(blocker: RemovalBlocker) async throws {
        let fixture = try await Self.makeFixture()
        let state = ContactListWindowState()
        state.selectedRow = .contact(sectionName: "Friends", contact: fixture.contact)

        switch blocker {
        case .search: state.isSearching = true
        case .addContact: state.isShowingAddContact = true
        case .joinRoom: state.isShowingJoinRoom = true
        case .bookmarks: state.isShowingBookmarks = true
        case .profile: state.isShowingProfile = true
        case .customStatus: state.customStatusPreset = CustomStatusPreset(presence: .away, message: "")
        case .inviteNickname: state.isEditingInviteNickname = true
        case .rowSheet: state.activeRowSheet = .rename(fixture.contact)
        case .pendingRemoval: state.pendingRemoval = fixture.contact
        }

        #expect(!state.canRemoveSelectedContact)
    }
}
