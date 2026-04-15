import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.ProtocolLayer {
    struct CarbonsTests {
        @Test @MainActor func `Carbon received on second resource`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let bob = try #require(harness.accounts["bob"])
                let aliceJID = try #require(BareJID.parse(TestCredentials.alice.jid))
                let client2 = try await Self.buildSecondAliceClient(harness: harness)

                // Bob sends a message to alice's bare JID.
                let bobClient = try #require(harness.environment.accountService.client(for: bob.accountID))
                let bobChat = try #require(await bobClient.module(ofType: ChatModule.self))
                let body = "msg-\(UUID().uuidString.prefix(8))"
                try await bobChat.sendMessage(to: .bare(aliceJID), body: body)

                // Listen on client2.events for the message — either as a carbon copy
                // (.messageCarbonReceived) if the server routed the original to the
                // primary resource, or as a direct delivery (.messageReceived) if the
                // server chose client2 as the delivery target. Both paths confirm
                // multi-resource delivery is working.
                try await TestHarness.waitForRawEvent(in: client2.events) { event in
                    if case let .messageCarbonReceived(forwarded) = event, forwarded.message.body == body { return true }
                    if case let .messageReceived(m) = event, m.body == body { return true }
                    return false
                }
            }
        }

        @Test @MainActor func `Carbon sent on second resource`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))
                let client2 = try await Self.buildSecondAliceClient(harness: harness)

                // Alice (primary, through harness) sends a message to bob.
                let body = "msg-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendMessage(
                    to: bobJID,
                    body: body,
                    accountID: alice.accountID
                )

                // Listen on client2.events for the sent carbon.
                try await TestHarness.waitForRawEvent(in: client2.events) { event in
                    if case let .messageCarbonSent(forwarded) = event, forwarded.message.body == body { return true }
                    return false
                }
            }
        }

        // MARK: - Helpers

        /// Builds a second alice connection with CarbonsModule enabled, registers cleanup, and waits for connect.
        @MainActor
        private static func buildSecondAliceClient(harness: TestHarness) async throws -> XMPPClient {
            let jid = try #require(BareJID.parse(TestCredentials.alice.jid))
            let username = try #require(jid.localPart)
            let domain = jid.domainPart

            var builder = XMPPClientBuilder(domain: domain, username: username, password: TestCredentials.alice.password)
            builder.withPreferredResource("test2")
            builder.withModule(CarbonsModule())
            builder.withModule(PresenceModule())
            let client = await builder.build()

            harness.addCleanup { await client.disconnect() }
            try await client.connect()

            // Wait for connected with timeout.
            try await TestHarness.waitForRawEvent(in: client.events, timeout: TestTimeout.connect) { event in
                if case .connected = event { return true }
                return false
            }

            return client
        }
    }
}
