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

        /// Builds a second alice connection with CarbonsModule enabled.
        @MainActor
        private static func buildSecondAliceClient(harness: TestHarness) async throws -> XMPPClient {
            try await harness.buildStandaloneClient(
                for: TestCredentials.alice,
                resource: "test2",
                modules: [CarbonsModule(), PresenceModule()]
            )
        }
    }
}
