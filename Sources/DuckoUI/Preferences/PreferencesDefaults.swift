import DuckoCore
import Foundation

enum PreferencesDefaults {
    nonisolated(unsafe) static let store: UserDefaults = {
        if let suite = BuildEnvironment.userDefaultsSuiteName {
            return UserDefaults(suiteName: suite) ?? .standard
        }
        return .standard
    }()
}
