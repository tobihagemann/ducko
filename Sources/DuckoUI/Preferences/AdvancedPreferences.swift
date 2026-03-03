import DuckoCore
import Foundation
import SwiftUI

@MainActor @Observable
final class AdvancedPreferences {
    private enum Keys {
        static let logLevel = "advancedLogLevel"
    }

    private static let defaults = PreferencesDefaults.store

    var logLevel: String {
        didSet { logLevelStorage = logLevel }
    }

    var dataLocation: URL {
        BuildEnvironment.appSupportDirectory
    }

    @ObservationIgnored
    @AppStorage(Keys.logLevel, store: AdvancedPreferences.defaults) private var logLevelStorage = "default"

    init() {
        self.logLevel = AdvancedPreferences.defaults.string(forKey: Keys.logLevel) ?? "default"
    }
}
