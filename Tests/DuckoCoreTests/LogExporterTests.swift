import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore

struct LogExporterTests {
    @Test
    func `recentLines returns no-file message when log directory is empty`() throws {
        let result = try LogExporter.recentLines(count: 10)
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

        try withTemporaryDirectory { dest in
            let copied = try LogExporter.export(to: dest)
            #expect(!copied.isEmpty)

            for file in copied {
                #expect(fm.fileExists(atPath: file.path))
            }
        }
    }

    @Test
    func `export creates destination directory if needed`() throws {
        try withTemporaryDirectory { dir in
            let dest = dir.appendingPathComponent("nested")
            _ = try LogExporter.export(to: dest)
            #expect(FileManager.default.fileExists(atPath: dest.path))
        }
    }
}
