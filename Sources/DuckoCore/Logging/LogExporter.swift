import Foundation

/// Bundles log files for export (bug reports, diagnostics).
public enum LogExporter {
    /// Copies all log files to the given destination directory, returning the paths of copied files.
    public static func export(to destination: URL) throws -> [URL] {
        let logsDir = LoggingConfiguration.logsDirectory
        let fm = FileManager.default

        guard fm.fileExists(atPath: logsDir.path) else {
            return []
        }

        guard destination.standardizedFileURL != logsDir.standardizedFileURL else {
            throw CocoaError(.fileWriteFileExists, userInfo: [
                NSLocalizedDescriptionKey: "Cannot export logs to the active log directory."
            ])
        }

        if !fm.fileExists(atPath: destination.path) {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        }

        let logFiles = try fm.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var copied: [URL] = []
        for file in logFiles {
            let dest = destination.appendingPathComponent(file.lastPathComponent)
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: file, to: dest)
            copied.append(dest)
        }
        return copied
    }

    /// Returns the content of the current log file's last N lines.
    public static func recentLines(count: Int = 50) throws -> String {
        let logFile = LoggingConfiguration.logsDirectory.appendingPathComponent(FileLogWriter.defaultFileName)
        guard FileManager.default.fileExists(atPath: logFile.path) else {
            return "(no log file found)"
        }
        let content = try String(contentsOf: logFile, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        let tail = lines.suffix(count + 1) // +1 because last element may be empty after trailing newline
        return tail.joined(separator: "\n")
    }
}
