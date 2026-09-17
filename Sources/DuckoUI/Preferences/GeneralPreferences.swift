import DuckoCore
import Foundation
import ServiceManagement
import SwiftUI

@MainActor @Observable
public final class GeneralPreferences {
    private enum Keys {
        static let showInMenuBar = "generalShowInMenuBar"
    }

    private static let defaults = PreferencesDefaults.store

    public var showInMenuBar: Bool {
        didSet { Self.defaults.set(showInMenuBar, forKey: Keys.showInMenuBar) }
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
    private var launchAtLoginEnabled: Bool = false

    public init() {
        self.showInMenuBar = GeneralPreferences.defaults.object(forKey: Keys.showInMenuBar) as? Bool ?? true
        self.launchAtLoginEnabled = Self.readLaunchAtLogin()
    }

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
