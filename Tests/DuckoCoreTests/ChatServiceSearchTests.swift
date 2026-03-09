import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let testConversationID = UUID()
private let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!

private func makeStore() -> MockPersistenceStore {
    MockPersistenceStore()
}

@MainActor
private func makeChatService(store: MockPersistenceStore) -> ChatService {
    ChatService(store: store, filterPipeline: MessageFilterPipeline())
}

private func seedMessages(store: MockPersistenceStore, conversationID: UUID) async {
    let bodies = [
        "Hello world",
        "How are you?",
        "I'm fine, thanks",
        "Let's meet at the cafe",
        "See you at the CAFE tomorrow"
    ]
    for (index, body) in bodies.enumerated() {
        let message = ChatMessage(
            id: UUID(),
            conversationID: conversationID,
            fromJID: contactJID.description,
            body: body,
            timestamp: Date(timeIntervalSince1970: Double(index) * 60),
            isOutgoing: index.isMultiple(of: 2),
            isRead: true,
            isDelivered: false,
            isEdited: false,
            type: "chat"
        )
        await store.addMessage(message)
    }
}

enum ChatServiceSearchTests {
    @MainActor
    struct SearchMessages {
        @Test
        func `filters messages case insensitively`() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)
            await seedMessages(store: store, conversationID: testConversationID)

            let results = try await service.searchMessages(for: testConversationID, query: "cafe")
            #expect(results.count == 2)
            let allContainCafe = results.allSatisfy { $0.body.localizedStandardContains("cafe") }
            #expect(allContainCafe)
        }

        @Test
        func `no matches returns empty`() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)
            await seedMessages(store: store, conversationID: testConversationID)

            let results = try await service.searchMessages(for: testConversationID, query: "nonexistent")
            #expect(results.isEmpty)
        }

        @Test
        func `respects limit`() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)

            for index in 0 ..< 10 {
                let message = ChatMessage(
                    id: UUID(),
                    conversationID: testConversationID,
                    fromJID: contactJID.description,
                    body: "hello \(index)",
                    timestamp: Date(timeIntervalSince1970: Double(index) * 60),
                    isOutgoing: false,
                    isRead: true,
                    isDelivered: false,
                    isEdited: false,
                    type: "chat"
                )
                await store.addMessage(message)
            }

            let results = try await service.searchMessages(for: testConversationID, query: "hello", limit: 3)
            #expect(results.count == 3)
            // Newest 3 matches (hello 9, 8, 7) returned in chronological order
            #expect(results[0].body == "hello 7")
            #expect(results[1].body == "hello 8")
            #expect(results[2].body == "hello 9")
        }

        @Test
        func `returns chronological order`() async throws {
            let store = makeStore()
            let service = makeChatService(store: store)
            await seedMessages(store: store, conversationID: testConversationID)

            let results = try await service.searchMessages(for: testConversationID, query: "cafe")
            #expect(results.count == 2)
            #expect(results[0].timestamp < results[1].timestamp)
        }
    }
}
