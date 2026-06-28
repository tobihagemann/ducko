import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoUI

@MainActor
struct ChatWindowStateTests {
    private static let jidString = "bob@example.com"

    private struct Fixture {
        let windowState: ChatWindowState
        let transcripts: MockTranscriptStore
        let accountID: UUID
    }

    private static func makeFixture() async throws -> Fixture {
        let store = MockPersistenceStore()
        let transcripts = MockTranscriptStore()
        let jid = try #require(BareJID.parse(jidString))
        let aliceJID = try #require(BareJID.parse("alice@example.com"))
        let account = Account(
            id: UUID(),
            jid: aliceJID,
            isEnabled: true,
            connectOnLaunch: false,
            createdAt: Date()
        )
        await store.addAccount(account)
        await store.addConversation(Conversation(
            id: UUID(),
            accountID: account.id,
            jid: jid,
            type: .chat,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            createdAt: Date()
        ))
        let environment = AppEnvironment(
            store: store,
            transcripts: transcripts,
            credentialStore: NullCredentialStore()
        )
        try await environment.accountService.loadAccounts()
        let windowState = ChatWindowState(jidString: jidString, accountID: account.id, environment: environment)
        await windowState.load()
        return Fixture(windowState: windowState, transcripts: transcripts, accountID: account.id)
    }

    @Test func `windowState carries the opened accountID`() async throws {
        let fixture = try await Self.makeFixture()
        #expect(fixture.windowState.accountID == fixture.accountID)
    }

    @Test func `windowState resolves the contact under its own account when the JID is on two`() async throws {
        let store = MockPersistenceStore()
        let transcripts = MockTranscriptStore()
        let peerJID = try #require(BareJID.parse(Self.jidString))
        let accountA = try Account(id: UUID(), jid: #require(BareJID.parse("a@example.com")), isEnabled: true, connectOnLaunch: false, createdAt: Date())
        let accountB = try Account(id: UUID(), jid: #require(BareJID.parse("b@example.com")), isEnabled: true, connectOnLaunch: false, createdAt: Date())
        await store.addAccount(accountA)
        await store.addAccount(accountB)

        // Same peer JID rostered on both accounts with distinct names.
        try await store.upsertContact(Contact(id: UUID(), accountID: accountA.id, jid: peerJID, name: "Bob-A", subscription: .both, groups: [], isBlocked: false, createdAt: Date()))
        try await store.upsertContact(Contact(id: UUID(), accountID: accountB.id, jid: peerJID, name: "Bob-B", subscription: .both, groups: [], isBlocked: false, createdAt: Date()))

        let environment = AppEnvironment(store: store, transcripts: transcripts, credentialStore: NullCredentialStore())
        try await environment.accountService.loadAccounts()
        try await environment.rosterService.loadContacts(for: accountA.id)
        try await environment.rosterService.loadContacts(for: accountB.id)

        let windowState = ChatWindowState(jidString: Self.jidString, accountID: accountB.id, environment: environment)
        await windowState.load()

        #expect(windowState.accountID == accountB.id)
        #expect(windowState.contact?.name == "Bob-B")
    }

    @Test func `loadOlderMessages sets lastLoadHistoryError when server fetch fails`() async throws {
        let fixture = try await Self.makeFixture()
        #expect(fixture.windowState.lastLoadHistoryError == nil)

        // No connected client → `fetchServerHistory` throws `ChatServiceError.notConnected`.
        await fixture.windowState.loadOlderMessages()

        #expect(fixture.windowState.lastLoadHistoryError != nil)
    }

    @Test func `clearLoadHistoryError resets the error state`() async throws {
        let fixture = try await Self.makeFixture()
        await fixture.windowState.loadOlderMessages()
        try #require(fixture.windowState.lastLoadHistoryError != nil)

        fixture.windowState.clearLoadHistoryError()

        #expect(fixture.windowState.lastLoadHistoryError == nil)
    }

    @Test func `loadOlderMessages clears prior lastLoadHistoryError on success`() async throws {
        let fixture = try await Self.makeFixture()
        fixture.windowState.lastLoadHistoryError = "stale error"

        let conversationID = try #require(fixture.windowState.conversation?.id)
        let message = ChatMessage(
            id: UUID(),
            conversationID: conversationID,
            fromJID: Self.jidString,
            body: "older",
            timestamp: Date(timeIntervalSinceNow: -3600),
            isOutgoing: false,
            isDelivered: true,
            isEdited: false,
            type: "chat"
        )
        try await fixture.transcripts.appendMessage(message)

        await fixture.windowState.loadOlderMessages()

        #expect(fixture.windowState.lastLoadHistoryError == nil)
        #expect(fixture.windowState.messages.contains { $0.body == "older" })
    }

    @Test func `sendMessage captures typed ChatService errors and preserves body`() async throws {
        let fixture = try await Self.makeFixture()
        let typed = "Reach for the sky"

        // No connected client → `sendMessage` flows through the
        // `ChatService.ChatServiceError.notConnected` catch arm.
        await fixture.windowState.sendMessage(typed)

        #expect(fixture.windowState.lastSendError != nil)
        #expect(fixture.windowState.lastFailedSendBody == typed)
    }

    @Test func `clearSendError resets lastSendError`() async throws {
        let fixture = try await Self.makeFixture()
        fixture.windowState.lastSendError = "Send failed: invalid JID"
        try #require(fixture.windowState.lastSendError != nil)

        fixture.windowState.clearSendError()

        #expect(fixture.windowState.lastSendError == nil)
    }

    @Test func `roomSubject reflects a live service-side change, not the stale load-time copy`() async throws {
        let store = MockPersistenceStore()
        let transcripts = MockTranscriptStore()
        let roomJIDString = "room@conference.example.com"
        let roomJID = try #require(BareJID.parse(roomJIDString))
        let aliceJID = try #require(BareJID.parse("alice@example.com"))
        let account = Account(id: UUID(), jid: aliceJID, isEnabled: true, connectOnLaunch: false, createdAt: Date())
        await store.addAccount(account)
        await store.addConversation(Conversation(
            id: UUID(),
            accountID: account.id,
            jid: roomJID,
            type: .groupchat,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            createdAt: Date()
        ))

        let environment = AppEnvironment(store: store, transcripts: transcripts, credentialStore: NullCredentialStore())
        try await environment.accountService.loadAccounts()
        let windowState = ChatWindowState(jidString: roomJIDString, accountID: account.id, environment: environment)
        await windowState.load()
        #expect(windowState.roomSubject == nil)

        // A server-driven subject change updates the service's published cache.
        await environment.chatService.handleEvent(
            .roomSubjectChanged(room: roomJID, subject: "Daily standup", setter: nil),
            accountID: account.id
        )

        // roomSubject must read the live cache, while the frozen load-time copy stays nil.
        #expect(windowState.roomSubject == "Daily standup")
        #expect(windowState.conversation?.roomSubject == nil)
    }
}
