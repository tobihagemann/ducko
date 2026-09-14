import DuckoCore
import Foundation
import SwiftUI

@MainActor @Observable
final class AdvancedPreferences {
    private static let defaults = PreferencesDefaults.store

    var logLevel: LogLevelPreference {
        didSet { logLevelStorage = logLevel }
    }

    var dataLocation: URL {
        BuildEnvironment.appSupportDirectory
    }

    @ObservationIgnored
    @AppStorage(LogLevelPreference.userDefaultsKey, store: AdvancedPreferences.defaults)
    private var logLevelStorage: LogLevelPreference = .standard

    init() {
        self.logLevel = LogLevelPreference.current
    }
}
