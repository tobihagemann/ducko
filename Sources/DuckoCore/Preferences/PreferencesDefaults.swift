import Foundation

public enum PreferencesDefaults {
    public nonisolated(unsafe) static let store: UserDefaults = {
        if let suite = BuildEnvironment.userDefaultsSuiteName {
            return UserDefaults(suiteName: suite) ?? .standard
        }
        return .standard
    }()
}
