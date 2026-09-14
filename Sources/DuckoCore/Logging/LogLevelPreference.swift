import Foundation

/// The user-facing file-log verbosity preference: Preferences > Advanced writes it and the
/// file log handler reads it at every emit. One shared contract, so the picker's values
/// and the handler's interpretation can never desync. The raw values are the persisted
/// UserDefaults strings — `standard` keeps the historical `"default"` on disk.
public enum LogLevelPreference: String, CaseIterable, Sendable {
    case standard = "default"
    case debug
    case verbose

    public static let userDefaultsKey = "advancedLogLevel"

    /// The persisted preference, reading a missing or unrecognized value as `.standard`.
    public static var current: LogLevelPreference {
        PreferencesDefaults.store.string(forKey: userDefaultsKey).flatMap(LogLevelPreference.init(rawValue:)) ?? .standard
    }
}
