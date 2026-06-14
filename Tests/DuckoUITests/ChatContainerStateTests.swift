import DuckoCore
import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoUI

@MainActor
struct ChatContainerStateTests {
    private struct Fixture {
        let container: ChatContainerState
        let accountID: UUID
        let accountID2: UUID
    }

    private static func makeFixture() async throws -> Fixture {
        let store = MockPersistenceStore()
        let transcripts = MockTranscriptStore()
        let account = try Account(
            id: UUID(),
            jid: #require(BareJID.parse("alice@example.com")),
            isEnabled: true,
            connectOnLaunch: false,
            createdAt: Date()
        )
        let account2 = try Account(
            id: UUID(),
            jid: #require(BareJID.parse("alice@other.example")),
            isEnabled: true,
            connectOnLaunch: false,
            createdAt: Date()
        )
        await store.addAccount(account)
        await store.addAccount(account2)
        let environment = AppEnvironment(
            store: store,
            transcripts: transcripts,
            credentialStore: NullCredentialStore()
        )
        try await environment.accountService.loadAccounts()
        return Fixture(
            container: ChatContainerState(environment: environment),
            accountID: account.id,
            accountID2: account2.id
        )
    }

    private func key(_ jid: String, _ accountID: UUID) -> ConversationKey {
        ConversationKey(accountID: accountID, jid: jid)
    }

    @Test func `open appends a tab and selects it`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id = fixture.accountID

        container.open("bob@example.com", accountID: id)

        #expect(container.orderedTabs == [key("bob@example.com", id)])
        #expect(container.selectedKey == key("bob@example.com", id))
        #expect(container.hasTabs)
    }

    @Test func `opening an already-open chat selects its existing tab without duplicating`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id = fixture.accountID

        container.open("bob@example.com", accountID: id)
        container.open("carol@example.com", accountID: id)
        container.open("bob@example.com", accountID: id)

        #expect(container.orderedTabs == [key("bob@example.com", id), key("carol@example.com", id)])
        #expect(container.selectedKey == key("bob@example.com", id))
    }

    @Test func `close removes a tab and selects a neighbor`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id = fixture.accountID
        container.open("a@example.com", accountID: id)
        container.open("b@example.com", accountID: id)
        container.open("c@example.com", accountID: id)

        // Closing the middle tab while it is selected picks the tab that shifts into its slot.
        container.select(key("b@example.com", id))
        container.close(key("b@example.com", id))
        #expect(container.orderedTabs == [key("a@example.com", id), key("c@example.com", id)])
        #expect(container.selectedKey == key("c@example.com", id))

        // Closing the last tab picks the new last.
        container.select(key("c@example.com", id))
        container.close(key("c@example.com", id))
        #expect(container.orderedTabs == [key("a@example.com", id)])
        #expect(container.selectedKey == key("a@example.com", id))
    }

    @Test func `closing the final tab yields an empty container`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id = fixture.accountID
        container.open("solo@example.com", accountID: id)

        container.close(key("solo@example.com", id))

        #expect(container.orderedTabs.isEmpty)
        #expect(container.selectedKey == nil)
        #expect(!container.hasTabs)
        #expect(container.selectedState == nil)
    }

    @Test func `draft text is retained per tab across switches`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id = fixture.accountID
        container.open("bob@example.com", accountID: id)
        container.state(for: key("bob@example.com", id))?.draftText = "half-typed"

        container.open("carol@example.com", accountID: id)
        #expect(container.state(for: key("carol@example.com", id))?.draftText == "")

        container.select(key("bob@example.com", id))
        #expect(container.state(for: key("bob@example.com", id))?.draftText == "half-typed")
    }

    @Test func `a MUC PM is a distinct tab from its room`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id = fixture.accountID

        container.open("room@conference.example.com", accountID: id)
        container.open("room@conference.example.com/nick", accountID: id)

        #expect(container.orderedTabs.count == 2)
        #expect(container.orderedTabs.contains(key("room@conference.example.com", id)))
        #expect(container.orderedTabs.contains(key("room@conference.example.com/nick", id)))
        #expect(container.state(for: key("room@conference.example.com", id))
            !== container.state(for: key("room@conference.example.com/nick", id)))
    }

    @Test func `same JID under two accounts opens two distinct tabs`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id1 = fixture.accountID
        let id2 = fixture.accountID2

        container.open("bob@example.com", accountID: id1)
        container.open("bob@example.com", accountID: id2)

        #expect(container.orderedTabs.count == 2)
        #expect(container.orderedTabs.contains(key("bob@example.com", id1)))
        #expect(container.orderedTabs.contains(key("bob@example.com", id2)))
        #expect(container.state(for: key("bob@example.com", id1))
            !== container.state(for: key("bob@example.com", id2)))
    }

    @Test func `same JID opened twice under the same account is one tab`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id = fixture.accountID

        container.open("bob@example.com", accountID: id)
        container.open("bob@example.com", accountID: id)

        #expect(container.orderedTabs == [key("bob@example.com", id)])
    }
}
