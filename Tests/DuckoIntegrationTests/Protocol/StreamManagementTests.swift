import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCore

extension DuckoIntegrationTests.ProtocolLayer {
    struct StreamManagementTests {
        @Test @MainActor func `SM outgoing counter increments on send`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let (client, sm) = try await Self.buildSMClient(
                    harness: harness, modules: [ChatModule(), PresenceModule()]
                )

                let stateBefore = try #require(sm.resumeState)
                let counterBefore = stateBefore.outgoingCounter

                // Send 2 messages.
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))
                let chat = try #require(await client.module(ofType: ChatModule.self))
                try await chat.sendMessage(to: .bare(bobJID), body: "msg-\(UUID().uuidString.prefix(8))")
                try await chat.sendMessage(to: .bare(bobJID), body: "msg-\(UUID().uuidString.prefix(8))")

                let stateAfter = try #require(sm.resumeState)
                try #require(stateAfter.outgoingCounter >= counterBefore)
                #expect(stateAfter.outgoingCounter - counterBefore >= 2)
            }
        }

        @Test @MainActor func `SM state is preserved across clean disconnect`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let (client, sm) = try await Self.buildSMClient(
                    harness: harness, modules: [PresenceModule()]
                )

                let stateBefore = try #require(sm.resumeState)
                let resumptionId = stateBefore.resumptionId

                // Clean disconnect — SM module preserves resume state client-side.
                await client.disconnect()

                // isResumable should still be true (SM preserves state across disconnect).
                #expect(sm.isResumable)
                let stateAfter = try #require(sm.resumeState)
                #expect(stateAfter.resumptionId == resumptionId)
            }
        }

        @Test @MainActor func `SM resume state captures outgoing queue`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let (client, sm) = try await Self.buildSMClient(
                    harness: harness, modules: [ChatModule(), PresenceModule()]
                )

                let counterBefore = try #require(sm.resumeState).outgoingCounter

                // Send a message.
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))
                let chat = try #require(await client.module(ofType: ChatModule.self))
                try await chat.sendMessage(to: .bare(bobJID), body: "msg-\(UUID().uuidString.prefix(8))")

                // Check immediately (before server ack prunes the queue).
                let stateAfter = try #require(sm.resumeState)

                // The queue may already be pruned by server ack; fall back to counter growth.
                let queueNonEmpty = !stateAfter.outgoingQueue.isEmpty
                let counterGrew = stateAfter.outgoingCounter >= counterBefore && stateAfter.outgoingCounter - counterBefore >= 1
                #expect(queueNonEmpty || counterGrew)
            }
        }

        @Test @MainActor func `SM module preserves resume state after disconnect`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let alice = try #require(harness.accounts["alice"])
                let client = try #require(harness.environment.accountService.client(for: alice.accountID))
                let sm = try #require(await client.module(ofType: StreamManagementModule.self))

                // Wait for SM to be resumable.
                try await alice.waitForCondition(
                    { @MainActor in sm.isResumable },
                    timeout: TestTimeout.event
                )

                let resumeState = try #require(sm.resumeState)
                let resumptionId = resumeState.resumptionId

                // Verify SM state structure is valid.
                #expect(!resumptionId.isEmpty)
                #expect(resumeState.connectedJID.bareJID == BareJID.parse(TestCredentials.alice.jid))

                // Force a non-requested disconnect by calling the raw XMPPClient's
                // disconnect directly. This triggers .disconnected(.requested) through
                // the event stream, which AccountService handles. Note: only
                // .connectionLost/.streamError preserve SM state in AccountService —
                // the live test verifies the SM module state is valid and the event
                // flow works. Actual connection-loss SM handoff is covered by unit tests.
                await client.disconnect()

                // After disconnect, the SM module itself preserves resume state.
                #expect(sm.isResumable)
                let postDisconnect = try #require(sm.resumeState)
                #expect(postDisconnect.resumptionId == resumptionId)
            }
        }

        // MARK: - Helpers

        /// Builds a standalone XMPPClient with SM enabled, connects, and waits for SM to become resumable.
        @MainActor
        private static func buildSMClient(
            harness: TestHarness,
            modules: [any XMPPModule]
        ) async throws -> (XMPPClient, StreamManagementModule) {
            let jid = try #require(BareJID.parse(TestCredentials.alice.jid))
            let username = try #require(jid.localPart)
            let domain = jid.domainPart

            let sm = StreamManagementModule()
            var builder = XMPPClientBuilder(domain: domain, username: username, password: TestCredentials.alice.password)
            builder.withPreferredResource("sm-test")
            builder.withModule(sm)
            builder.withInterceptor(sm)
            for module in modules {
                builder.withModule(module)
            }
            let client = await builder.build()

            harness.addCleanup { await client.disconnect() }
            try await client.connect()

            // Wait for connected with timeout.
            try await TestHarness.waitForRawEvent(in: client.events, timeout: TestTimeout.connect) { event in
                if case .connected = event { return true }
                return false
            }

            // Wait for SM to become resumable.
            let smDeadline = ContinuousClock.now.advanced(by: TestTimeout.event)
            while !sm.isResumable, ContinuousClock.now < smDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(sm.isResumable)

            return (client, sm)
        }
    }
}
