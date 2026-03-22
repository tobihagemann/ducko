import Foundation

@MainActor @Observable
public final class LoggingPreferences {
    private enum Keys {
        static let debugLoggingEnabled = "loggingDebugEnabled"
    }

    private static let defaults = PreferencesDefaults.store

    // periphery:ignore - will be used by preferences UI
    public static let shared = LoggingPreferences()

    public var debugLoggingEnabled: Bool {
        didSet { Self.defaults.set(debugLoggingEnabled, forKey: Keys.debugLoggingEnabled) }
    }

    /// Thread-safe read for use in log handlers (off main actor).
    public nonisolated static var isDebugLoggingEnabled: Bool {
        PreferencesDefaults.store.bool(forKey: Keys.debugLoggingEnabled)
    }

    private init() {
        self.debugLoggingEnabled = Self.defaults.bool(forKey: Keys.debugLoggingEnabled)
    }
}
