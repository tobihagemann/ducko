import Foundation
import Logging

/// A swift-log `LogHandler` that writes log entries to a rotating file.
///
/// Uses a shared `FileLogWriter` actor for thread-safe file I/O. Rotation triggers when the
/// current log file exceeds `maxFileSize`, keeping at most `maxArchivedFiles` old files.
///
/// `logLevel` is kept at `.trace` so that `MultiplexLogHandler` passes all messages through.
/// Actual filtering is done dynamically via `minimumLevelProvider`, which reads from UserDefaults
/// to support runtime debug-mode toggling without re-bootstrapping the logging system.
struct FileLogHandler: LogHandler {
    private let label: String
    private let writer: FileLogWriter
    private let minimumLevelProvider: @Sendable () -> Logger.Level

    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]

    init(label: String, writer: FileLogWriter, minimumLevel: @escaping @Sendable () -> Logger.Level) {
        self.label = label
        self.writer = writer
        self.minimumLevelProvider = minimumLevel
    }

    // swiftlint:disable:next function_parameter_count
    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        guard level >= minimumLevelProvider() else { return }

        let timestamp = Date.now.formatted(Self.timestampStyle)
        let levelTag = level.rawValue.uppercased()
        let logLine = "[\(timestamp)] [\(levelTag)] [\(label)] \(message)\n"

        Task {
            await writer.write(logLine)
        }
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
}

// MARK: - File Log Writer

/// Actor managing thread-safe file writes with size-based rotation.
public actor FileLogWriter {
    public static let defaultFileName = "ducko.log"

    private let directory: URL
    private let fileName: String
    private let maxFileSize: UInt64
    private let maxArchivedFiles: Int
    private var fileHandle: FileHandle?

    public init(
        directory: URL,
        fileName: String = FileLogWriter.defaultFileName,
        maxFileSize: UInt64 = 5 * 1024 * 1024,
        maxArchivedFiles: Int = 5
    ) {
        self.directory = directory
        self.fileName = fileName
        self.maxFileSize = maxFileSize
        self.maxArchivedFiles = maxArchivedFiles
    }

    /// The path to the current log file.
    public var currentLogFile: URL {
        directory.appendingPathComponent(fileName)
    }

    /// All log files (current + archived), sorted by recency.
    public var allLogFiles: [URL] {
        var files: [URL] = []
        let current = currentLogFile
        if FileManager.default.fileExists(atPath: current.path) {
            files.append(current)
        }
        for i in 1 ... maxArchivedFiles {
            let archived = archivedFile(index: i)
            if FileManager.default.fileExists(atPath: archived.path) {
                files.append(archived)
            }
        }
        return files
    }

    func write(_ line: String) {
        guard let handle = ensureFileHandle() else { return }
        guard let data = line.data(using: .utf8) else { return }
        handle.write(data)
        rotateIfNeeded()
    }

    // MARK: - Rotation

    private func rotateIfNeeded() {
        guard let handle = fileHandle else { return }
        let size = handle.offsetInFile
        guard size >= maxFileSize else { return }

        handle.closeFile()
        fileHandle = nil

        // Shift archived files: N → N+1, delete oldest if over limit
        let fm = FileManager.default
        let oldest = archivedFile(index: maxArchivedFiles)
        try? fm.removeItem(at: oldest)

        for i in stride(from: maxArchivedFiles - 1, through: 1, by: -1) {
            let src = archivedFile(index: i)
            let dst = archivedFile(index: i + 1)
            if fm.fileExists(atPath: src.path) {
                try? fm.moveItem(at: src, to: dst)
            }
        }

        // Current → .1
        try? fm.moveItem(at: currentLogFile, to: archivedFile(index: 1))
    }

    private func archivedFile(index: Int) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        return directory.appendingPathComponent("\(base).\(index).\(ext)")
    }

    private func ensureFileHandle() -> FileHandle? {
        if let handle = fileHandle {
            return handle
        }

        let fm = FileManager.default
        let file = currentLogFile

        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }

        guard let handle = FileHandle(forWritingAtPath: file.path) else { return nil }
        handle.seekToEndOfFile()
        fileHandle = handle
        return handle
    }
}
