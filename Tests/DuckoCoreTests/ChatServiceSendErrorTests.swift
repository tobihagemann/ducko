import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// MARK: - Helpers

private struct TestError: Error {}

private let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!

private func makeStore() -> MockPersistenceStore {
    MockPersistenceStore()
}

private func makeTranscripts() -> MockTranscriptStore {
    MockTranscriptStore()
}

@MainActor
private func makeChatService(store: MockPersistenceStore, transcripts: MockTranscriptStore) -> ChatService {
    ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
}

// MARK: - Tests

enum ChatServiceSendErrorTests {
    struct SendMessageRollback {
        @Test
        @MainActor
        func `sendMessage failure appends retract amendment and throws`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let credentials = MockCredentialStore()
            let transport = MockTransport()
            let factory = MockXMPPClientFactory(transport: transport, modules: [ChatModule()])
            let accountService = makeAccountService(store: store, credentials: credentials, clientFactory: factory)
            let chatService = makeChatService(store: store, transcripts: transcripts)
            chatService.setAccountService(accountService)

            let connectTask = Task { @MainActor in
                try await accountService.createAndConnect(
                    jidString: testJIDString, password: "secret",
                    host: "example.com", port: 5222
                )
            }
            await simulateNoTLSConnect(transport)
            let accountID = try await connectTask.value

            let conversation = try await chatService.openConversation(for: contactJID, accountID: accountID)
            await chatService.selectConversation(conversation.id, accountID: accountID)

            await transport.simulateSendFailure(TestError())

            await #expect(throws: TestError.self) {
                try await chatService.sendMessage(to: contactJID, body: "hi", accountID: accountID)
            }

            let persistedMessages = await transcripts.messages
            let stanzaID = try #require(persistedMessages.last?.stanzaID)

            let amendments = await transcripts.amendments
            #expect(amendments.count == 1)
            #expect(amendments.first?.amendment.action == .retract)
            #expect(amendments.first?.amendment.targetStanzaID == stanzaID)
            #expect(amendments.first?.conversationID == conversation.id)

            // The active conversation reload applies the retract amendment to the
            // visible message: it stays in the list but `isRetracted` flips and
            // `body` is cleared. (The mock transcript store mirrors the real
            // amendment-application semantics.)
            #expect(chatService.messages.count == 1)
            #expect(chatService.messages.first?.isRetracted == true)
            #expect(chatService.messages.first?.body.isEmpty == true)

            await accountService.disconnect(accountID: accountID)
        }
    }
}
