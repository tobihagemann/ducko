import Foundation
import Logging

/// Bootstraps the swift-log system with dual backends: OSLog (Console.app/Xcode) + file (user log collection).
public enum LoggingConfiguration {
    /// The directory where log files are stored, following `BuildEnvironment` isolation.
    public static let logsDirectory: URL = BuildEnvironment.appSupportDirectory.appendingPathComponent("Logs", isDirectory: true)

    /// Shared file writer used by all `FileLogHandler` instances.
    public static let fileWriter = FileLogWriter(directory: logsDirectory)

    private nonisolated(unsafe) static var isBootstrapped = false

    /// Configures the logging system. Safe to call multiple times; only the first call takes effect.
    public static func bootstrap() {
        guard !isBootstrapped else { return }
        isBootstrapped = true
        LoggingSystem.bootstrap { label in
            MultiplexLogHandler([
                OSLogHandler(label: label),
                FileLogHandler(label: label, writer: fileWriter, minimumLevel: {
                    LoggingPreferences.isDebugLoggingEnabled ? .trace : .info
                })
            ])
        }
    }
}
