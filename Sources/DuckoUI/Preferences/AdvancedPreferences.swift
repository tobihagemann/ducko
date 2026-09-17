import DuckoCore
import Foundation
import SwiftUI

@MainActor @Observable
final class AdvancedPreferences {
    var logLevel: LogLevelPreference {
        didSet { logLevelStorage = logLevel }
    }

    var dataLocation: URL {
        BuildEnvironment.appSupportDirectory
    }

    @ObservationIgnored
    @AppStorage(LogLevelPreference.userDefaultsKey)
    private var logLevelStorage: LogLevelPreference = .standard

    init(defaults: UserDefaults = PreferencesDefaults.store) {
        _logLevelStorage = AppStorage(wrappedValue: .standard, LogLevelPreference.userDefaultsKey, store: defaults)
        self.logLevel = LogLevelPreference.read(from: defaults)
    }
}
