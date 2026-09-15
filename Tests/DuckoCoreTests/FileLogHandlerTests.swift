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

    private func event(_ level: Logger.Level, _ message: Logger.Message) -> LogEvent {
        LogEvent(level: level, message: message, metadata: nil, source: nil, file: #fileID, function: #function, line: #line)
    }

    // MARK: - File Creation

    @Test
    func `creates log file on first write`() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = FileLogWriter(directory: dir)
        writer.write("[test] hello\n")

        let logFile = dir.appendingPathComponent("ducko.log")
        #expect(FileManager.default.fileExists(atPath: logFile.path))
    }

    // MARK: - Log Format

    @Test
    func `writes expected format`() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = FileLogWriter(directory: dir)

        let handler = FileLogHandler(label: "im.ducko.test", writer: writer, minimumLevel: { .trace })
        handler.log(event: event(.info, "Test message"))

        let logFile = dir.appendingPathComponent("ducko.log")
        let content = try String(contentsOf: logFile, encoding: .utf8)
        #expect(content.contains("[INFO]"))
        #expect(content.contains("[im.ducko.test]"))
        #expect(content.contains("Test message"))
    }

    @Test
    func `preserves emission order`() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = FileLogWriter(directory: dir)

        let handler = FileLogHandler(label: "im.ducko.test", writer: writer, minimumLevel: { .trace })
        for i in 0 ..< 200 {
            handler.log(event: event(.info, "line \(i)"))
        }

        let logFile = dir.appendingPathComponent("ducko.log")
        let content = try String(contentsOf: logFile, encoding: .utf8)
        let messages = content.split(separator: "\n").map { $0.split(separator: "] ").last.map(String.init) }
        #expect(messages == (0 ..< 200).map { "line \($0)" })
    }

    // MARK: - Level Filtering

    @Test
    func `filters messages below minimum level`() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = FileLogWriter(directory: dir)

        let handler = FileLogHandler(label: "im.ducko.test", writer: writer, minimumLevel: { .warning })
        handler.log(event: event(.debug, "Should be skipped"))
        handler.log(event: event(.warning, "Should appear"))

        let logFile = dir.appendingPathComponent("ducko.log")
        let content = try String(contentsOf: logFile, encoding: .utf8)
        #expect(!content.contains("Should be skipped"))
        #expect(content.contains("Should appear"))
    }

    // MARK: - Rotation

    @Test
    func `rotates when file exceeds max size`() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Use a tiny max size to trigger rotation quickly
        let writer = FileLogWriter(directory: dir, maxFileSize: 100, maxArchivedFiles: 3)

        // Write enough data to trigger at least one rotation
        for i in 0 ..< 20 {
            writer.write("Log entry number \(i) with some padding to fill the file quickly\n")
        }

        let archivedFile = dir.appendingPathComponent("ducko.1.log")
        #expect(FileManager.default.fileExists(atPath: archivedFile.path))
    }

    @Test
    func `respects max archived files limit`() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = FileLogWriter(directory: dir, maxFileSize: 50, maxArchivedFiles: 2)

        for i in 0 ..< 50 {
            writer.write("Log entry \(i) with padding to trigger many rotations easily\n")
        }

        // Should have at most ducko.log, ducko.1.log, ducko.2.log
        let overLimit = dir.appendingPathComponent("ducko.3.log")
        #expect(!FileManager.default.fileExists(atPath: overLimit.path))
    }

    // MARK: - All Log Files

    @Test
    func `allLogFiles returns existing log files`() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = FileLogWriter(directory: dir, maxFileSize: 200, maxArchivedFiles: 3)

        // Write enough to create the current file and at least one archive
        for i in 0 ..< 20 {
            writer.write("Entry \(i) with padding to trigger rotation here\n")
        }

        let files = writer.allLogFiles
        #expect(!files.isEmpty)
        // All returned files should have .log extension
        for file in files {
            #expect(file.pathExtension == "log")
        }
    }
}
