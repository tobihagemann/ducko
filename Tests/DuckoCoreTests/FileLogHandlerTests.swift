import Foundation
import Logging
import Testing
@testable import DuckoCore

struct FileLogHandlerTests {
    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - File Creation

    @Test
    func `creates log file on first write`() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = FileLogWriter(directory: dir)
        await writer.write("[test] hello\n")

        let logFile = dir.appendingPathComponent("ducko.log")
        #expect(FileManager.default.fileExists(atPath: logFile.path))
    }

    // MARK: - Log Format

    @Test
    func `writes expected format`() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = FileLogWriter(directory: dir)

        var handler = FileLogHandler(label: "im.ducko.test", writer: writer, minimumLevel: { .trace })
        handler.log(
            level: .info,
            message: "Test message",
            metadata: nil,
            source: "Test",
            file: #file,
            function: #function,
            line: #line
        )

        // Give the async Task time to complete
        try await Task.sleep(for: .milliseconds(100))

        let logFile = dir.appendingPathComponent("ducko.log")
        let content = try String(contentsOf: logFile, encoding: .utf8)
        #expect(content.contains("[INFO]"))
        #expect(content.contains("[im.ducko.test]"))
        #expect(content.contains("Test message"))
    }

    // MARK: - Level Filtering

    @Test
    func `filters messages below minimum level`() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = FileLogWriter(directory: dir)

        var handler = FileLogHandler(label: "im.ducko.test", writer: writer, minimumLevel: { .warning })
        handler.log(
            level: .debug,
            message: "Should be skipped",
            metadata: nil,
            source: "Test",
            file: #file,
            function: #function,
            line: #line
        )
        handler.log(
            level: .warning,
            message: "Should appear",
            metadata: nil,
            source: "Test",
            file: #file,
            function: #function,
            line: #line
        )

        try await Task.sleep(for: .milliseconds(100))

        let logFile = dir.appendingPathComponent("ducko.log")
        let content = try String(contentsOf: logFile, encoding: .utf8)
        #expect(!content.contains("Should be skipped"))
        #expect(content.contains("Should appear"))
    }

    // MARK: - Rotation

    @Test
    func `rotates when file exceeds max size`() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Use a tiny max size to trigger rotation quickly
        let writer = FileLogWriter(directory: dir, maxFileSize: 100, maxArchivedFiles: 3)

        // Write enough data to trigger at least one rotation
        for i in 0 ..< 20 {
            await writer.write("Log entry number \(i) with some padding to fill the file quickly\n")
        }

        let archivedFile = dir.appendingPathComponent("ducko.1.log")
        #expect(FileManager.default.fileExists(atPath: archivedFile.path))
    }

    @Test
    func `respects max archived files limit`() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = FileLogWriter(directory: dir, maxFileSize: 50, maxArchivedFiles: 2)

        for i in 0 ..< 50 {
            await writer.write("Log entry \(i) with padding to trigger many rotations easily\n")
        }

        // Should have at most ducko.log, ducko.1.log, ducko.2.log
        let overLimit = dir.appendingPathComponent("ducko.3.log")
        #expect(!FileManager.default.fileExists(atPath: overLimit.path))
    }

    // MARK: - All Log Files

    @Test
    func `allLogFiles returns existing log files`() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = FileLogWriter(directory: dir, maxFileSize: 200, maxArchivedFiles: 3)

        // Write enough to create the current file and at least one archive
        for i in 0 ..< 20 {
            await writer.write("Entry \(i) with padding to trigger rotation here\n")
        }

        let files = await writer.allLogFiles
        #expect(!files.isEmpty)
        // All returned files should have .log extension
        for file in files {
            #expect(file.pathExtension == "log")
        }
    }
}
