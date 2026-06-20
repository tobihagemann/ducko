import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

/// Proves `PresenceService` re-broadcasts a non-default held status on an automatic reconnect (a fresh
/// `.connected`), so a held away/dnd/available-with-message survives the blank-available presence that
/// `PresenceModule.handleConnect()` sends on every connect. Plain default-available and `.offline` must not
/// re-broadcast. Wires a real handshake (like `PresenceReadinessGateTests`) so `connectedClient(for:)` is
/// non-nil and `awaitInitialPresenceSent()` settles.
enum PresenceReconnectReapplyTests {
    struct Scenario {
        let status: PresenceService.PresenceStatus
        let message: String?
        let shouldBroadcast: Bool
        let marker: String
    }

    struct Reapply {
        @Test(arguments: [
            Scenario(status: .away, message: nil, shouldBroadcast: true, marker: "away"),
            Scenario(status: .dnd, message: nil, shouldBroadcast: true, marker: "dnd"),
            Scenario(status: .available, message: "lunch", shouldBroadcast: true, marker: "lunch"),
            Scenario(status: .available, message: nil, shouldBroadcast: false, marker: ""),
            Scenario(status: .offline, message: nil, shouldBroadcast: false, marker: "")
        ])
        @MainActor
        func `reapply re-broadcasts only a non-default held status on reconnect`(
            scenario: Scenario
        ) async throws {
            let status = scenario.status
            let message = scenario.message
            let store = MockPersistenceStore()
            let credentials = MockCredentialStore()
            let transport = MockTransport()
            let factory = MockXMPPClientFactory(
                transport: transport,
                modules: [PEPModule(), PresenceModule(), CapsModule()]
            )
            let accountService = AccountService(store: store, credentialStore: credentials, clientFactory: factory)
            let presenceService = PresenceService()
            presenceService.setAccountService(accountService)

            let accountID = try await accountService.createAccount(
                jidString: "alice@example.com", host: "example.com", port: 5222
            )
            let (_, connectTask) = try await driveMockConnect(
                accountService,
                accountID: accountID,
                transport: transport,
                awaitInitialPresence: true
            )

            let boundJID = try #require(FullJID.parse("alice@example.com/ducko"))

            presenceService.myPresence = status
            presenceService.myStatusMessage = message
            await transport.clearSentBytes()

            // `handleEvent` runs the reapply inline, so once it returns the broadcast (if any) has been sent.
            await presenceService.handleEvent(.connected(boundJID), accountID: accountID)

            let sent = await transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            if scenario.shouldBroadcast {
                #expect(sent.contains { $0.contains("<presence") && $0.contains(scenario.marker) })
            } else {
                #expect(sent.allSatisfy { !$0.contains("<presence") })
            }

            connectTask.cancel()
            await accountService.disconnect(accountID: accountID)
        }
    }
}
