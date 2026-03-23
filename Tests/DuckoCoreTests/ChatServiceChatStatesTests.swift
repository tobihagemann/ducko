import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// MARK: - Helpers

private let testAccountID = UUID()
private let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!

@MainActor
private func makeChatService(store: MockPersistenceStore, transcripts: MockTranscriptStore) -> ChatService {
    ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
}

// MARK: - Tests

enum ChatServiceChatStatesTests {
    struct TypingState {
        @Test
        @MainActor
        func `Chat state event updates typingStates`() async {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = makeChatService(store: store, transcripts: transcripts)

            await service.handleEvent(
                .chatStateChanged(from: contactJID, state: .composing),
                accountID: testAccountID
            )

            #expect(service.typingStates[contactJID] == .composing)
        }

        @Test
        @MainActor
        func `Active state replaces composing`() async {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = makeChatService(store: store, transcripts: transcripts)

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
