import DuckoCore
import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoUI

@MainActor
struct ChatWindowStateTests {
    private static let jidString = "bob@example.com"

    private struct Fixture {
        let windowState: ChatWindowState
        let transcripts: MockTranscriptStore
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
        let windowState = ChatWindowState(jidString: jidString, environment: environment)
        await windowState.load()
        return Fixture(windowState: windowState, transcripts: transcripts)
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
}
