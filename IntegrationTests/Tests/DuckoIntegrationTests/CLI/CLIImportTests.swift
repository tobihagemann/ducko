import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIImportTests {
        @Test
        @MainActor func `import adium --dry-run reports discovered logs without importing`() async throws {
            try await CLIProcess.withProcess { cli in
                let logsDir = try Self.makeSyntheticAdiumTree()
                await cli.addCleanup { try? FileManager.default.removeItem(at: logsDir) }

                let output = try await cli.run(["import", "adium", "--path", logsDir.path, "--dry-run"])
                #expect(output.exitCode == 0)
                #expect(output.stdout.contains("Discovered "))
                #expect(output.stdout.contains("Dry run"))
                // A dry run must not import: the real-import summary line is absent.
                #expect(!output.stdout.contains("Import complete:"))
            }
        }

        @Test
        @MainActor func `import adium imports messages and skips duplicates on re-import`() async throws {
            try await CLIProcess.withProcess { cli in
                let logsDir = try Self.makeSyntheticAdiumTree()
                await cli.addCleanup { try? FileManager.default.removeItem(at: logsDir) }

                let imported = try await cli.run(["import", "adium", "--path", logsDir.path])
                #expect(imported.exitCode == 0)
                #expect(imported.stdout.contains("Import complete:"))
                #expect(imported.stdout.contains("Messages imported: \(Self.seededMessageCount)"))

                // The store/transcripts persist under this profile's directory, so a
                // second import of the same logs hits the idempotent duplicate path.
                let reimported = try await cli.run(["import", "adium", "--path", logsDir.path])
                #expect(reimported.exitCode == 0)
                #expect(reimported.stdout.contains("Messages imported: 0"))
                #expect(reimported.stdout.contains("Duplicates skipped: \(Self.seededMessageCount)"))
            }
        }

        // MARK: - Fixture

        /// Number of `<message>` rows the synthetic `.chatlog` carries.
        private static let seededMessageCount = 2

        /// Writes a `Jabber.<acct>/<contact>/<contact (date).chatlog>/<file>.xml`
        /// tree under a unique temp dir, mirroring `AdiumImportServiceTests`, and
        /// returns the root directory.
        private static func makeSyntheticAdiumTree() throws -> URL {
            let xml = """
            <?xml version="1.0" encoding="UTF-8" ?>
            <chat xmlns="http://purl.org/net/ulf/ns/0.4-02" account="saibot@exnet.me" service="Jabber">
            <message sender="saibot@exnet.me" time="2016-01-12T00:31:17+0100" alias="saibot"><div>hello</div></message>
            <message sender="buddy@exnet.me" time="2016-01-12T00:31:34+0100" alias="buddy"><div>hi</div></message>
            </chat>
            """

            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ducko-inttest-adium-\(UUID().uuidString)")
            let chatlogDir = tmpDir
                .appendingPathComponent("Jabber.saibot@exnet.me")
                .appendingPathComponent("buddy@exnet.me")
                .appendingPathComponent("buddy@exnet.me (2016-01-12T00.31.17+0100).chatlog")
            try FileManager.default.createDirectory(at: chatlogDir, withIntermediateDirectories: true)
            let xmlFile = chatlogDir.appendingPathComponent("buddy@exnet.me (2016-01-12T00.31.17+0100).xml")
            try xml.write(to: xmlFile, atomically: true, encoding: .utf8)
            return tmpDir
        }
    }
}
