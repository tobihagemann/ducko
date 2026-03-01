import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// MARK: - Helpers

private let testAccountID = UUID()
private let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!

@MainActor
private func makeChatService(store: MockPersistenceStore) -> ChatService {
    ChatService(store: store, filterPipeline: MessageFilterPipeline())
}

// MARK: - Tests

enum ChatServiceChatStatesTests {
    struct TypingState {
        @Test("Chat state event updates typingStates")
        @MainActor
        func chatStateUpdatesTypingStates() async {
            let store = MockPersistenceStore()
            let service = makeChatService(store: store)

            await service.handleEvent(
                .chatStateChanged(from: contactJID, state: .composing),
                accountID: testAccountID
            )

            #expect(service.typingStates[contactJID] == .composing)
        }

        @Test("Active state replaces composing")
        @MainActor
        func activeReplacesComposing() async {
            let store = MockPersistenceStore()
            let service = makeChatService(store: store)

            await service.handleEvent(
                .chatStateChanged(from: contactJID, state: .composing),
                accountID: testAccountID
            )
            #expect(service.typingStates[contactJID] == .composing)

            await service.handleEvent(
                .chatStateChanged(from: contactJID, state: .active),
                accountID: testAccountID
            )
            #expect(service.typingStates[contactJID] == .active)
        }
    }
}
