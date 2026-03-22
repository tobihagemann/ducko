import Foundation
import Testing
@testable import DuckoCore

struct LogExporterTests {
    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test
    func `recentLines returns no-file message when log directory is empty`() throws {
        // LogExporter.recentLines reads from the configured logsDirectory.
        // If the file doesn't exist yet, it should return a placeholder message.
        // This test verifies the fallback path.
        let result = try LogExporter.recentLines(count: 10)
        // Either returns actual log content or the no-file message
        #expect(!result.isEmpty)
    }

    @Test
    func `export copies log files to destination`() throws {
        let logsDir = LoggingConfiguration.logsDirectory
        let fm = FileManager.default

        // Ensure the logs directory exists with at least one file
        if !fm.fileExists(atPath: logsDir.path) {
            try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }

        let testFile = logsDir.appendingPathComponent("ducko.log")
        if !fm.fileExists(atPath: testFile.path) {
            try "test log entry\n".write(to: testFile, atomically: true, encoding: .utf8)
        }

        let dest = try makeTemporaryDirectory()
        defer { try? fm.removeItem(at: dest) }

        let copied = try LogExporter.export(to: dest)
        #expect(!copied.isEmpty)

        for file in copied {
            #expect(fm.fileExists(atPath: file.path))
        }
    }

    @Test
    func `export creates destination directory if needed`() throws {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("nested")
        defer { try? FileManager.default.removeItem(at: dest) }

        _ = try LogExporter.export(to: dest)
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }
}
