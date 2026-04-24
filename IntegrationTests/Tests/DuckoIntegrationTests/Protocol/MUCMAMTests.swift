import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.ProtocolLayer {
    struct MUCMAMTests {
        @Test @MainActor func `Room archive returns sent messages`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")
                let bob = try #require(harness.accounts["bob"])
                _ = try await harness.joinRoom(roomJID, as: "bob", using: "bob")

                let aliceMUC = try await harness.module(MUCModule.self, for: "alice")

                // Send 3 messages with UUID bodies.
                var sentBodies: [String] = []
                for _ in 0 ..< 3 {
                    let body = "msg-\(UUID().uuidString.prefix(8))"
                    sentBodies.append(body)
                    try await aliceMUC.sendMessage(to: roomJID, body: body)

                    // Wait for bob to receive each before sending next (ensures server persistence).
                    _ = try await bob.waitForEvent { event in
                        if case let .roomMessageReceived(m) = event, m.body == body { return true }
                        return false
                    }
                }

                // Query the room archive.
                let aliceMAM = try await harness.module(MAMModule.self, for: "alice")
                let (messages, _) = try await aliceMAM.queryMessages(MAMModule.Query(to: roomJID))

                // Filter by UUID bodies (archive may contain join/subject notifications).
                let matchedBodies = messages.compactMap(\.forwarded.message.body).filter { sentBodies.contains($0) }
                #expect(matchedBodies.count == 3)
                for body in sentBodies {
                    #expect(matchedBodies.contains(body))
                }
            }
        }
    }
}
