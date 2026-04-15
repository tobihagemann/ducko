import DuckoCore
import Foundation
import Testing

extension DuckoIntegrationTests.ProtocolLayer {
    struct ProfileTests {
        // MARK: - Service Layer

        /// Precondition (documented in `TestCredentials`): alice has a
        /// pre-published vCard. The test round-trips an existing profile
        /// because `ProfileService` has no delete API — synthesizing a
        /// baseline then restoring would leak vCard state server-side.
        @Test(.timeLimit(.minutes(1))) @MainActor func `Service publishProfile persists a modified profile and fetchOwnProfile restores it`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])
                let alice = try #require(harness.accounts["alice"])

                await harness.environment.profileService.fetchOwnProfile(accountID: alice.accountID)
                let originalProfile = try #require(harness.environment.profileService.ownProfile)

                harness.addCleanup {
                    try? await harness.environment.profileService.publishProfile(originalProfile, accountID: alice.accountID)
                }

                var modified = originalProfile
                modified.nickname = "ducko-inttest-\(UUID().uuidString.prefix(8))"
                try await harness.environment.profileService.publishProfile(modified, accountID: alice.accountID)

                await harness.environment.profileService.fetchOwnProfile(accountID: alice.accountID)
                try await alice.waitForCondition({ @MainActor in
                    harness.environment.profileService.ownProfile?.nickname == modified.nickname
                })
            }
        }
    }
}
