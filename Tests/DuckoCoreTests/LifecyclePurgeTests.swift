import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

/// End-to-end coverage for the lifecycle teardown paths that bypass the services' `.disconnected` handlers:
/// `AccountService.disconnect(accountID:)` cancels the account's event task before `.disconnected` is delivered,
/// and `deleteAccount(_:)` never routes through it. Both must still purge every per-account cache via the
/// `purgeAccount` wiring. Driving a real `AppEnvironment` (rather than a hand-mirrored `wireServices`) keeps the
/// fixture honest as services are added to production wiring.
enum LifecyclePurgeTests {
    struct Purge {
        private func makePresence(show: XMPPPresence.Show? = nil, status: String? = nil) -> XMPPPresence {
            var presence = XMPPPresence(type: nil)
            presence.show = show
            presence.status = status
            return presence
        }

        /// Builds a real `AppEnvironment`, creates one account, and seeds every per-account cache the lifecycle
        /// purge should clear (roster, presence, bookmarks, avatar, profile), asserting each is populated.
        @MainActor
        private func makeSeededEnvironment() async throws -> (env: AppEnvironment, accountID: UUID) {
            let env = AppEnvironment(
                store: MockPersistenceStore(),
                transcripts: MockTranscriptStore(),
                credentialStore: NullCredentialStore()
            )

            let accountID = try await env.accountService.createAccount(jidString: "alice@example.com")
            let peerJID = try #require(BareJID(localPart: "bob", domainPart: "example.com"))
            let peerFrom = try JID.full(#require(FullJID(bareJID: peerJID, resourcePart: "res")))

            await env.rosterService.handleEvent(
                .rosterLoaded([RosterItem(jid: peerJID, name: "Bob", subscription: .both, ask: false, groups: [])]),
                accountID: accountID
            )
            await env.presenceService.handleEvent(
                .presenceUpdated(from: peerFrom, presence: makePresence(show: .away, status: "Busy")),
                accountID: accountID
            )
            env.bookmarksService.setBookmarksForTesting([RoomBookmark(jidString: "room@conference.example.com")], accountID: accountID)
            env.avatarService.setOwnAvatarHashForTesting("hash", accountID: accountID)
            env.profileService.setOwnProfileForTesting(ProfileInfo(fullName: "Alice"), accountID: accountID)

            #expect(!env.rosterService.groups.isEmpty)
            #expect(!env.presenceService.contactPresences.isEmpty)
            #expect(!env.presenceService.contactStatusMessages.isEmpty)
            #expect(!env.bookmarksService.bookmarks.isEmpty)
            #expect(env.avatarService.ownAvatarHash(for: accountID) != nil)
            #expect(env.profileService.ownProfile(for: accountID) != nil)

            return (env, accountID)
        }

        @MainActor
        private func expectAllPurged(_ env: AppEnvironment, _ accountID: UUID) {
            #expect(env.rosterService.groups.isEmpty)
            #expect(env.presenceService.contactPresences.isEmpty)
            #expect(env.presenceService.contactStatusMessages.isEmpty)
            #expect(env.bookmarksService.bookmarks.isEmpty)
            #expect(env.avatarService.ownAvatarHash(for: accountID) == nil)
            #expect(env.profileService.ownProfile(for: accountID) == nil)
        }

        @Test
        @MainActor
        func `disconnect purges every per-account cache on the path that bypasses the event handler`() async throws {
            let (env, accountID) = try await makeSeededEnvironment()

            await env.accountService.disconnect(accountID: accountID)

            expectAllPurged(env, accountID)
        }

        @Test
        @MainActor
        func `deleteAccount purges every per-account cache`() async throws {
            let (env, accountID) = try await makeSeededEnvironment()

            try await env.accountService.deleteAccount(accountID)

            expectAllPurged(env, accountID)
        }
    }
}
