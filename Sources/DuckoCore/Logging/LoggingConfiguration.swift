import Foundation
import Logging

/// Bootstraps the swift-log system with dual backends: OSLog (Console.app/Xcode) + file (user log collection).
public enum LoggingConfiguration {
    /// The directory where log files are stored, following `BuildEnvironment` isolation.
    public static let logsDirectory: URL = BuildEnvironment.appSupportDirectory.appendingPathComponent("Logs", isDirectory: true)

    /// Shared file writer used by all `FileLogHandler` instances.
    public static let fileWriter = FileLogWriter(directory: logsDirectory)

    /// Resolves the dynamic file-log level from the persisted preference at every emit, so a
    /// runtime change (Preferences > Advanced > Log Level) takes effect without re-bootstrapping.
    static var fileLogLevel: Logger.Level {
        fileLogLevel(from: PreferencesDefaults.store)
    }

    static func fileLogLevel(from defaults: UserDefaults) -> Logger.Level {
        switch LogLevelPreference.read(from: defaults) {
        case .standard: .info
        case .debug: .debug
        case .verbose: .trace
        }
    }

    private static let latch = BootstrapLatch()

    /// Configures the logging system. Safe to call multiple times; only the first call takes effect.
    public static func bootstrap() {
        latch.runOnce {
            LoggingSystem.bootstrap { label in
                MultiplexLogHandler([
                    OSLogHandler(label: label),
                    FileLogHandler(label: label, writer: fileWriter, minimumLevel: {
                        fileLogLevel
                    })
                ])
            }
        }
    }
}
