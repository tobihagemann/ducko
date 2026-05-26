import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIAvatarTests {
        @Test
        @MainActor func `avatar get fetches the own avatar or reports none`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                let savePath = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ducko-inttest-avatar-\(UUID().uuidString).png").path
                await cli.addCleanup { try? FileManager.default.removeItem(atPath: savePath) }

                // No avatar baseline is guaranteed for alice (`TestCredentials`), so accept either the
                // saved-file path or the not-found message — both are clean exits.
                let output = try await cli.run(["avatar", "get", alice.jid, "--save", savePath])
                #expect(output.exitCode == 0)
                #expect(output.stdout.contains("Saved avatar to") || output.stdout.contains("No avatar found"))
            }
        }
    }
}
