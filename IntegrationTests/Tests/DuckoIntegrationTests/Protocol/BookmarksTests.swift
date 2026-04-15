import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.ProtocolLayer {
    struct BookmarksTests {
        // MARK: - Service Layer

        @Test @MainActor func `Bookmark add and remove round-trips via PEP`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let alice = try #require(harness.accounts["alice"])
                let roomJID = try await harness.createEphemeralRoom(using: "alice")

                // Register the remove BEFORE adding so a crashed test still
                // retracts the PEP item server-side.
                harness.addCleanup {
                    try? await harness.environment.bookmarksService.removeBookmark(
                        jidString: roomJID.description,
                        accountID: alice.accountID
                    )
                }

                let bookmark = RoomBookmark(
                    jidString: roomJID.description,
                    name: "inttest",
                    autojoin: false,
                    nickname: "alice",
                    password: nil
                )
                // Bookmarks2 publishes with access_model=whitelist (XEP-0223 private
                // storage). Prosody's mod_pep does not fan out +notify to the owner's
                // own resources, so the publish IQ result is the authoritative signal —
                // `addBookmark` returned successfully means the server accepted it.
                // Local state is updated in lockstep with that success.
                try await harness.environment.bookmarksService.addBookmark(bookmark, accountID: alice.accountID)
                try await alice.waitForCondition({ @MainActor in
                    harness.environment.bookmarksService.bookmarks.contains { $0.jidString == roomJID.description }
                })

                try await harness.environment.bookmarksService.removeBookmark(
                    jidString: roomJID.description,
                    accountID: alice.accountID
                )
                try await alice.waitForCondition({ @MainActor in
                    !harness.environment.bookmarksService.bookmarks.contains { $0.jidString == roomJID.description }
                })
            }
        }

        @Test(.timeLimit(.minutes(2))) @MainActor func `Autojoin bookmark drives joinRoom on the next connection`() async throws {
            // Room JID persists across both harness scopes; only phase 2 destroys
            // the room and retracts the bookmark. Swift `defer` cannot await, so
            // a catch-block recovery harness is the async-safe cleanup path.
            let roomJID = try #require(BareJID.parse("inttest-\(UUID().uuidString.prefix(8))@\(TestCredentials.mucService)"))
            do {
                try await Self.bookmarkPhase1(roomJID: roomJID)
                try await Self.bookmarkPhase2(roomJID: roomJID)
            } catch {
                await Self.bookmarkRecovery(roomJID: roomJID)
                throw error
            }
        }

        // MARK: - Helpers

        /// Phase 1: create the room server-side and publish an autojoin bookmark
        /// for it. Does NOT destroy the room or retract the bookmark — phase 2
        /// owns that cleanup so the bookmark survives the harness teardown.
        @MainActor
        private static func bookmarkPhase1(roomJID: BareJID) async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])
                let alice = try #require(harness.accounts["alice"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
                let mucModule = try #require(await aliceClient.module(ofType: MUCModule.self))

                // Do NOT use harness.createEphemeralRoom — it auto-registers a
                // destroy-cleanup that would fire at phase 1 teardown and
                // defeat the spec's "auto-join an existing room" intent.
                try await harness.environment.chatService.joinRoom(
                    jid: roomJID, nickname: "alice", accountID: alice.accountID
                )
                let joinEvent = try await alice.waitForEvent { event in
                    if case let .roomJoined(room, _, _) = event, room == roomJID { return true }
                    return false
                }
                if case let .roomJoined(_, _, isNewlyCreated) = joinEvent, isNewlyCreated {
                    try await mucModule.acceptDefaultConfig(roomJID)
                }

                let bookmark = RoomBookmark(
                    jidString: roomJID.description,
                    name: nil, autojoin: true,
                    nickname: "alice", password: nil
                )
                // See the round-trip test for why `.pepItemsPublished` can't be used
                // as the publish signal on this server. The IQ result from
                // `addBookmark` means the server persisted it; phase 2's fresh
                // `loadBookmarks` (PEP items IQ get) verifies it cross-session.
                try await harness.environment.bookmarksService.addBookmark(bookmark, accountID: alice.accountID)
            }
        }

        /// Phase 2: fresh harness, flip autojoin on, explicitly reload bookmarks
        /// (setUp already consumed the `.connected` event that handleEvent uses),
        /// then clean both pieces of server state on the success path.
        @MainActor
        private static func bookmarkPhase2(roomJID: BareJID) async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])
                let alice = try #require(harness.accounts["alice"])
                harness.environment.bookmarksService.autoJoinEnabled = true

                // setUp waits for .rosterLoaded which fires after .connected,
                // so BookmarksService.handleEvent(.connected) has already run
                // with autoJoinEnabled=false and produced no auto-join. This
                // explicit reload is what drives the join in phase 2.
                await harness.environment.bookmarksService.loadBookmarks(accountID: alice.accountID)

                _ = try await alice.waitForEvent { event in
                    if case let .roomJoined(room, _, _) = event, room == roomJID { return true }
                    return false
                }

                try await harness.environment.bookmarksService.removeBookmark(
                    jidString: roomJID.description, accountID: alice.accountID
                )
                try await harness.environment.chatService.destroyRoom(
                    jid: roomJID, reason: nil, accountID: alice.accountID
                )
            }
        }

        /// Recovery harness: runs on any thrown error from phase 1 or phase 2.
        /// All operations are best-effort so a reconnect failure doesn't mask
        /// the original error.
        @MainActor
        private static func bookmarkRecovery(roomJID: BareJID) async {
            try? await TestHarness.withHarness { recovery in
                try? await recovery.setUp(accounts: ["alice": TestCredentials.alice])
                guard let aliceID = recovery.accounts["alice"]?.accountID else { return }
                try? await recovery.environment.bookmarksService.removeBookmark(
                    jidString: roomJID.description, accountID: aliceID
                )
                try? await recovery.environment.chatService.destroyRoom(
                    jid: roomJID, reason: nil, accountID: aliceID
                )
            }
        }
    }
}
