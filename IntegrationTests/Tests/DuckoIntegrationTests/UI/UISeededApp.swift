import Foundation

/// Shared launch helper for UI integration tests that need a pre-seeded
/// account before `DuckoApp` boots into its contact list.
///
/// Why direct `CLIProcess` instead of `CLIProcess.withProcess`: the scoped
/// helper invokes `CLIProcess.cleanupProfileDirectory()` in its teardown,
/// which would wipe the seeded credentials at
/// `~/Library/Application Support/Ducko-Dev-<profile>/` before `DuckoApp`
/// launches. We instantiate `CLIProcess` directly so the seed survives, and
/// `AppAccessor`'s own `.postExit` cleanup queue reaps the shared profile
/// directory at the end via `CLIProcess.removeProfileDirectory(profile:)`.
@MainActor
enum UISeededApp {
    /// Seeds Alice's account into a fresh `DUCKO_PROFILE` and runs `body`
    /// against an `AppAccessor` launched into the contact list.
    ///
    /// Naming mirrors `with…` siblings (`CLIProcess.withProcess`,
    /// `AppAccessor.withAppAccessor`, `TestHarness.withHarness`).
    static func withSeededApp<T: Sendable>(
        _ body: sending (AppAccessor) async throws -> T
    ) async throws -> T {
        let profile = "inttest-ui-\(UUID().uuidString.prefix(8))"
        let cli = CLIProcess(profile: profile)
        do {
            try await cli.seedAccount(TestCredentials.alice)
        } catch {
            // Seed may have created a partial profile dir before failing —
            // reap it explicitly because `AppAccessor.withAppAccessor` (and
            // its post-exit cleanup) is not entered when seeding throws.
            await CLIProcess.removeProfileDirectory(profile: profile)
            throw error
        }

        return try await AppAccessor.withAppAccessor(profile: profile, target: .contactList) { app in
            try await body(app)
        }
    }
}
