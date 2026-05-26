import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIBookmarksTests {
        @Test(arguments: ["plain", "json", "ansi"])
        @MainActor func `bookmarks list runs across output formats`(format: String) async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                // The bookmark baseline is operator-managed and may be empty ("No bookmarks."), so assert the
                // command completes cleanly across formats rather than pinning specific bookmark content.
                let output = try await cli.run(["bookmarks", "list", "--output", format])
                #expect(output.exitCode == 0)
                #expect(!output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
