import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// MARK: - Helpers

private let testAccountID = UUID()
private let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!

private func makeStore() -> MockPersistenceStore {
    MockPersistenceStore()
}

@MainActor
private func makeChatService(store: MockPersistenceStore) -> ChatService {
    ChatService(store: store, filterPipeline: MessageFilterPipeline())
}

// MARK: - Tests

enum ChatServiceMAMTests {
    struct RosterLoadedHandler {
        @Test
        @MainActor
        func `rosterLoaded event is handled without error`() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            // Fire .rosterLoaded — syncRecentHistory exits early (no client), no crash
            await service.handleEvent(.rosterLoaded([]), accountID: testAccountID)

            // Give the fire-and-forget Task time to complete
            try await Task.sleep(for: .milliseconds(50))

            // No conversations created (sync had no client, did nothing)
            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations.isEmpty)
        }
    }

    struct FetchServerHistory {
        @Test
        @MainActor
        func `Returns empty when no client available`() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            let (messages, hasMore) = try await service.fetchServerHistory(
                jid: contactJID, accountID: testAccountID, before: nil, limit: 50
            )

            #expect(messages.isEmpty)
            #expect(!hasMore)
        }

        @Test
        @MainActor
        func `String overload throws for invalid JID`() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            await #expect(throws: ChatService.ChatServiceError.self) {
                _ = try await service.fetchServerHistory(
                    jidString: "", accountID: testAccountID, before: nil, limit: 50
                )
            }
        }
    }
}
