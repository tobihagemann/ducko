import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.ProtocolLayer {
    struct SmokeTests {
        @Test @MainActor func `Alice connects to server`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])
            }
        }

        @Test @MainActor func `Alice sends direct message to Bob`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])

                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))
                let messageBody = "smoke test \(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendMessage(
                    to: bobJID,
                    body: messageBody,
                    accountID: alice.accountID
                )

                _ = try await bob.waitForEvent { event in
                    if case let .messageReceived(message) = event, message.body == messageBody {
                        return true
                    }
                    return false
                }
            }
        }

        @Test @MainActor func `Disconnects cleanly`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let alice = try #require(harness.accounts["alice"])
                await harness.environment.accountService.disconnect(accountID: alice.accountID)
                try await harness.waitUntilDisconnected("alice")
            }
        }
    }
}
