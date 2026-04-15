import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.ProtocolLayer {
    struct MAMTests {
        @Test @MainActor func `Archive query returns recent messages`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))

                let aliceChat = try #require(await aliceClient.module(ofType: ChatModule.self))

                // Send 3 messages with UUID bodies.
                var sentBodies: [String] = []
                for _ in 0 ..< 3 {
                    let body = "msg-\(UUID().uuidString.prefix(8))"
                    sentBodies.append(body)
                    try await aliceChat.sendMessage(to: .bare(bobJID), body: body)

                    // Wait for bob to receive each (ensures server persistence).
                    _ = try await bob.waitForEvent { event in
                        if case let .messageReceived(m) = event, m.body == body { return true }
                        return false
                    }
                }

                // Query the last page of alice's archive filtered by bob.
                // The archive is shared across test runs, so we fetch the tail
                // to find our just-sent messages.
                let aliceMAM = try #require(await aliceClient.module(ofType: MAMModule.self))
                let (messages, _) = try await aliceMAM.queryMessages(
                    MAMModule.Query(with: bobJID, before: .lastPage)
                )

                // Filter by UUID bodies (last page may contain other recent messages).
                let matchedBodies = messages.compactMap(\.forwarded.message.body).filter { sentBodies.contains($0) }
                #expect(matchedBodies.count == 3)
                for body in sentBodies {
                    #expect(matchedBodies.contains(body))
                }
            }
        }

        @Test @MainActor func `Pagination via RSM`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                // Use an ephemeral MUC room for an isolated archive.
                let roomJID = try await harness.createEphemeralRoom(using: "alice")

                let bob = try #require(harness.accounts["bob"])
                let bobClient = try #require(harness.environment.accountService.client(for: bob.accountID))
                let bobMUC = try #require(await bobClient.module(ofType: MUCModule.self))

                try await bobMUC.joinRoom(roomJID, nickname: "bob")
                harness.addCleanup { try? await bobMUC.leaveRoom(roomJID) }

                _ = try await bob.waitForEvent { event in
                    if case let .roomJoined(room, _, _) = event, room == roomJID { return true }
                    return false
                }

                let alice = try #require(harness.accounts["alice"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
                let aliceMUC = try #require(await aliceClient.module(ofType: MUCModule.self))

                // Send 5 messages.
                var sentBodies: [String] = []
                for _ in 0 ..< 5 {
                    let body = "msg-\(UUID().uuidString.prefix(8))"
                    sentBodies.append(body)
                    try await aliceMUC.sendMessage(to: roomJID, body: body)

                    _ = try await bob.waitForEvent { event in
                        if case let .roomMessageReceived(m) = event, m.body == body { return true }
                        return false
                    }
                }

                let aliceMAM = try #require(await aliceClient.module(ofType: MAMModule.self))

                // Page 1: max 2.
                let (page1Messages, page1Fin) = try await aliceMAM.queryMessages(MAMModule.Query(to: roomJID, max: 2))
                let page1Bodies = page1Messages.compactMap(\.forwarded.message.body).filter { sentBodies.contains($0) }
                #expect(page1Bodies.count == 2)
                let page1Cursor = try #require(page1Fin.last)
                #expect(!page1Fin.complete)

                // Page 2: after cursor, max 2.
                let (page2Messages, page2Fin) = try await aliceMAM.queryMessages(
                    MAMModule.Query(to: roomJID, after: page1Cursor, max: 2)
                )
                let page2Bodies = page2Messages.compactMap(\.forwarded.message.body).filter { sentBodies.contains($0) }
                #expect(page2Bodies.count == 2)
                // Page 2 bodies should differ from page 1.
                #expect(Set(page1Bodies).isDisjoint(with: page2Bodies))

                // Page 3: last page.
                let page2Cursor = try #require(page2Fin.last)
                let (page3Messages, page3Fin) = try await aliceMAM.queryMessages(
                    MAMModule.Query(to: roomJID, after: page2Cursor, max: 2)
                )
                let page3Bodies = page3Messages.compactMap(\.forwarded.message.body).filter { sentBodies.contains($0) }
                #expect(page3Bodies.count == 1)
                #expect(page3Fin.complete)
            }
        }
    }
}
