import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.ProtocolLayer {
    /// CSI has no observable XMPPEvent; sendActive/sendInactive also suppress
    /// no-op writes. Every test in this suite asserts lack-of-throw and that
    /// subsequent operations on the connection still succeed.
    struct CSITests {
        // MARK: - Protocol Layer

        @Test @MainActor func `CSI sendActive does not throw and the connection stays healthy`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
                let csi = try #require(await aliceClient.module(ofType: CSIModule.self))
                let chat = try #require(await aliceClient.module(ofType: ChatModule.self))
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))

                try await csi.sendActive()

                let body = "csi-active-\(UUID().uuidString.prefix(8))"
                try await chat.sendMessage(to: .bare(bobJID), body: body)
                _ = try await bob.waitForEvent { event in
                    if case let .messageReceived(m) = event, m.body == body { return true }
                    return false
                }
            }
        }

        @Test @MainActor func `CSI sendInactive does not throw and messages still deliver after reactivation`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
                let csi = try #require(await aliceClient.module(ofType: CSIModule.self))
                let chat = try #require(await aliceClient.module(ofType: ChatModule.self))
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))

                try await csi.sendInactive()
                // Restore active before the harness exits — the server may queue
                // stanzas while inactive, so tests should not leave the
                // connection in inactive state.
                try await csi.sendActive()

                let body = "csi-inactive-\(UUID().uuidString.prefix(8))"
                try await chat.sendMessage(to: .bare(bobJID), body: body)
                _ = try await bob.waitForEvent { event in
                    if case let .messageReceived(m) = event, m.body == body { return true }
                    return false
                }
            }
        }

        // MARK: - Service Layer

        @Test @MainActor func `AccountService setAppActive does not throw and messaging continues`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))

                // isAppActive is private on AccountService, so assert indirectly
                // by confirming a probe message still delivers after each state
                // transition.
                await harness.environment.accountService.setAppActive(false)

                let inactiveBody = "csi-probe-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendMessage(
                    to: bobJID, body: inactiveBody, accountID: alice.accountID
                )
                _ = try await bob.waitForEvent { event in
                    if case let .messageReceived(m) = event, m.body == inactiveBody { return true }
                    return false
                }

                await harness.environment.accountService.setAppActive(true)

                let activeBody = "csi-probe-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendMessage(
                    to: bobJID, body: activeBody, accountID: alice.accountID
                )
                _ = try await bob.waitForEvent { event in
                    if case let .messageReceived(m) = event, m.body == activeBody { return true }
                    return false
                }
            }
        }
    }
}
