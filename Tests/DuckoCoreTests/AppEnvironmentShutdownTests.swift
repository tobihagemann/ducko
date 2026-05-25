import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

@MainActor
private func makeEnvironment() -> AppEnvironment {
    AppEnvironment(
        store: MockPersistenceStore(),
        transcripts: MockTranscriptStore(),
        credentialStore: NullCredentialStore()
    )
}

// MARK: - Tests

enum AppEnvironmentShutdownTests {
    struct Shutdown {
        @Test
        @MainActor
        func `shutdown returns promptly when no service tasks are pending`() async {
            let environment = makeEnvironment()

            let clock = ContinuousClock()
            let elapsed = await clock.measure {
                await environment.shutdown(within: .seconds(3))
            }
            #expect(elapsed < .seconds(1))
        }

        @Test
        @MainActor
        func `shutdown cancels a pending task and returns once it unwinds`() async {
            let environment = makeEnvironment()
            let slow = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
            environment.registerPendingTaskForTesting(slow)

            let clock = ContinuousClock()
            let elapsed = await clock.measure {
                await environment.shutdown(within: .seconds(5))
            }
            // Cancellation unwinds the sleep, so shutdown returns well before the 5 s deadline.
            #expect(elapsed < .seconds(2))
            #expect(slow.isCancelled)
        }

        @Test
        @MainActor
        func `shutdown returns at the deadline when a task ignores cancellation`() async {
            let environment = makeEnvironment()
            // Swallows cancellation (`try?`) and runs past the deadline, so the bounded await in
            // `shutdown` must fall through on its own timer rather than wait for the task to finish.
            let stuck = Task {
                let end = ContinuousClock.now + .seconds(2)
                while ContinuousClock.now < end {
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            environment.registerPendingTaskForTesting(stuck)

            let clock = ContinuousClock()
            let deadline = Duration.milliseconds(300)
            let elapsed = await clock.measure {
                await environment.shutdown(within: deadline)
            }
            #expect(elapsed >= deadline)
            #expect(elapsed < deadline + .seconds(1))
            #expect(stuck.isCancelled)

            _ = await stuck.value
        }
    }

    struct ServiceTaskDraining {
        @Test
        @MainActor
        func `shutdown drains pending tasks owned by ChatService and FileTransferService`() async {
            let environment = makeEnvironment()
            let chatTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
            let fileTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
            environment.chatService.registerPendingTaskForTesting(chatTask)
            environment.fileTransferService.registerPendingTaskForTesting(fileTask)

            await environment.shutdown(within: .seconds(5))

            // shutdown concatenates each service's `takePendingTasks()`; dropping a source would leave the
            // corresponding task uncancelled.
            #expect(chatTask.isCancelled)
            #expect(fileTask.isCancelled)
        }

        @Test
        @MainActor
        func `ChatService takePendingTasks drains and clears typing-debounce tasks`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let transport = MockTransport()
            let factory = MockXMPPClientFactory(transport: transport, modules: [ChatStatesModule()])
            let accountService = makeAccountService(store: store, clientFactory: factory)
            let chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
            chatService.setAccountService(accountService)

            let connectTask = Task { @MainActor in
                try await accountService.createAndConnect(
                    jidString: testJIDString, password: "secret", host: "example.com", port: 5222
                )
            }
            await simulateNoTLSConnect(transport)
            let accountID = try await connectTask.value

            ChatPreferences.shared.enableChatStates = true
            let peer = try #require(BareJID(localPart: "contact", domainPart: "example.com"))
            await chatService.userIsTyping(in: peer, accountID: accountID)

            let drained = chatService.takePendingTasks()
            #expect(drained.count == 1)
            // The store is cleared, so a second drain is empty.
            #expect(chatService.takePendingTasks().isEmpty)
            for task in drained {
                task.cancel()
            }

            await accountService.disconnect(accountID: accountID)
        }
    }
}
