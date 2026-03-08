import Foundation
import ServiceManagement
import SwiftUI

@MainActor @Observable
final class GeneralPreferences {
    private enum Keys {
        static let showInDock = "generalShowInDock"
    }

    private static let defaults = PreferencesDefaults.store

    var showInDock: Bool {
        didSet { showInDockStorage = showInDock }
    }

    var launchAtLogin: Bool {
        get { launchAtLoginEnabled }
        set { setLaunchAtLogin(newValue) }
    }

    var isLaunchAtLoginAvailable: Bool {
        #if DEBUG
            return false
        #else
            return true
        #endif
    }

    @ObservationIgnored
    @AppStorage(Keys.showInDock, store: GeneralPreferences.defaults) private var showInDockStorage = true

    @ObservationIgnored
    private var launchAtLoginEnabled: Bool = false

    init() {
        self.showInDock = GeneralPreferences.defaults.object(forKey: Keys.showInDock) as? Bool ?? true
        self.launchAtLoginEnabled = Self.readLaunchAtLogin()
    }

    // MARK: - Private

    private static func readLaunchAtLogin() -> Bool {
        #if DEBUG
            return false
        #else
            return SMAppService.mainApp.status == .enabled
        #endif
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        #if DEBUG
            return
        #else
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLoginEnabled = enabled
            } catch {
                // Registration failed — revert to current state
                launchAtLoginEnabled = Self.readLaunchAtLogin()
            }
        #endif
    }
}
