import DuckoCore
import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoUI

@MainActor
struct ChatContainerStateTests {
    private static func makeContainer() async throws -> ChatContainerState {
        let store = MockPersistenceStore()
        let transcripts = MockTranscriptStore()
        let account = try Account(
            id: UUID(),
            jid: #require(BareJID.parse("alice@example.com")),
            isEnabled: true,
            connectOnLaunch: false,
            createdAt: Date()
        )
        await store.addAccount(account)
        let environment = AppEnvironment(
            store: store,
            transcripts: transcripts,
            credentialStore: NullCredentialStore()
        )
        try await environment.accountService.loadAccounts()
        return ChatContainerState(environment: environment)
    }

    @Test func `open appends a tab and selects it`() async throws {
        let container = try await Self.makeContainer()

        container.open("bob@example.com")

        #expect(container.orderedTabs == ["bob@example.com"])
        #expect(container.selectedJID == "bob@example.com")
        #expect(container.hasTabs)
    }

    @Test func `opening an already-open chat selects its existing tab without duplicating`() async throws {
        let container = try await Self.makeContainer()

        container.open("bob@example.com")
        container.open("carol@example.com")
        container.open("bob@example.com")

        #expect(container.orderedTabs == ["bob@example.com", "carol@example.com"])
        #expect(container.selectedJID == "bob@example.com")
    }

    @Test func `close removes a tab and selects a neighbor`() async throws {
        let container = try await Self.makeContainer()
        container.open("a@example.com")
        container.open("b@example.com")
        container.open("c@example.com")

        // Closing the middle tab while it is selected picks the tab that shifts into its slot.
        container.select("b@example.com")
        container.close("b@example.com")
        #expect(container.orderedTabs == ["a@example.com", "c@example.com"])
        #expect(container.selectedJID == "c@example.com")

        // Closing the last tab picks the new last.
        container.select("c@example.com")
        container.close("c@example.com")
        #expect(container.orderedTabs == ["a@example.com"])
        #expect(container.selectedJID == "a@example.com")
    }

    @Test func `closing the final tab yields an empty container`() async throws {
        let container = try await Self.makeContainer()
        container.open("solo@example.com")

        container.close("solo@example.com")

        #expect(container.orderedTabs.isEmpty)
        #expect(container.selectedJID == nil)
        #expect(!container.hasTabs)
        #expect(container.selectedState == nil)
    }

    @Test func `draft text is retained per tab across switches`() async throws {
        let container = try await Self.makeContainer()
        container.open("bob@example.com")
        container.state(for: "bob@example.com")?.draftText = "half-typed"

        container.open("carol@example.com")
        #expect(container.state(for: "carol@example.com")?.draftText == "")

        container.select("bob@example.com")
        #expect(container.state(for: "bob@example.com")?.draftText == "half-typed")
    }

    @Test func `a MUC PM is a distinct tab from its room`() async throws {
        let container = try await Self.makeContainer()

        container.open("room@conference.example.com")
        container.open("room@conference.example.com/nick")

        #expect(container.orderedTabs.count == 2)
        #expect(container.orderedTabs.contains("room@conference.example.com"))
        #expect(container.orderedTabs.contains("room@conference.example.com/nick"))
        #expect(container.state(for: "room@conference.example.com")
            !== container.state(for: "room@conference.example.com/nick"))
    }
}
