import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

/// Covers the lifecycle-purge wiring that lives at the `AppEnvironment` seam: the per-account event-dispatch
/// cancellation a user-initiated disconnect performs (so a queued stale event can't repopulate purged state),
/// and the per-account avatar isolation the global→per-account refactor introduced.
enum AppEnvironmentPurgeTests {
    @MainActor
    private static func makeEnvironment(store: MockPersistenceStore) -> AppEnvironment {
        AppEnvironment(store: store, transcripts: MockTranscriptStore(), credentialStore: NullCredentialStore())
    }

    struct DispatchCancellation {
        @Test
        @MainActor
        func `user-initiated disconnect cancels a queued roster event so it can't repopulate the cleared cache`() async throws {
            let store = MockPersistenceStore()
            let env = AppEnvironmentPurgeTests.makeEnvironment(store: store)

            let accountID = try await env.accountService.createAccount(jidString: "alice@example.com")
            let peer = try #require(BareJID(localPart: "bob", domainPart: "example.com"))
            // Seed a contact so the roster event, if it ran, would publish a non-empty merge.
            try await store.upsertContact(Contact(id: UUID(), accountID: accountID, jid: peer, subscription: .both, groups: [], isBlocked: false, createdAt: Date()))

            // Queue a roster-loaded fan-out task through the real dispatch closure, then disconnect before it
            // runs. `disconnect` has no client to await here, so its synchronous prefix cancels the task first.
            env.accountService.onEvent?(.rosterLoaded([RosterItem(jid: peer, name: "Bob", subscription: .both, ask: false, groups: [])]), accountID)
            await env.accountService.disconnect(accountID: accountID)

            // Let the cancelled task attempt to run; it must bail at its top-level `Task.isCancelled` check
            // rather than fetch + republish the just-purged cache.
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            #expect(env.rosterService.groups.isEmpty)
        }
    }

    struct AvatarIsolation {
        @Test
        @MainActor
        func `disconnect purges only the disconnected account's avatar hash`() async throws {
            let store = MockPersistenceStore()
            let env = AppEnvironmentPurgeTests.makeEnvironment(store: store)

            let aliceID = try await env.accountService.createAccount(jidString: "alice@example.com")
            let bobID = try await env.accountService.createAccount(jidString: "bob@example.com")
            env.avatarService.setOwnAvatarHashForTesting("hash-alice", accountID: aliceID)
            env.avatarService.setOwnAvatarHashForTesting("hash-bob", accountID: bobID)

            await env.accountService.disconnect(accountID: aliceID)

            // Per-account isolation: Alice's hash is gone, Bob's survives.
            #expect(env.avatarService.ownAvatarHash(for: aliceID) == nil)
            #expect(env.avatarService.ownAvatarHash(for: bobID) == "hash-bob")
        }

        @Test
        @MainActor
        func `deleteAccount purges only the deleted account's avatar hash`() async throws {
            let store = MockPersistenceStore()
            let env = AppEnvironmentPurgeTests.makeEnvironment(store: store)

            let aliceID = try await env.accountService.createAccount(jidString: "alice@example.com")
            let bobID = try await env.accountService.createAccount(jidString: "bob@example.com")
            env.avatarService.setOwnAvatarHashForTesting("hash-alice", accountID: aliceID)
            env.avatarService.setOwnAvatarHashForTesting("hash-bob", accountID: bobID)

            try await env.accountService.deleteAccount(aliceID)

            #expect(env.avatarService.ownAvatarHash(for: aliceID) == nil)
            #expect(env.avatarService.ownAvatarHash(for: bobID) == "hash-bob")
        }
    }
}
