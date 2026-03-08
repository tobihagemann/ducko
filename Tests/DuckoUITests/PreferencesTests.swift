import Foundation
import Testing
@testable import DuckoUI

private nonisolated(unsafe) let defaults = PreferencesDefaults.store

// MARK: - GeneralPreferences Tests

@MainActor
struct GeneralPreferencesTests {
    @Test func `default show in dock is true`() {
        // Remove any stored value to test the default
        defaults.removeObject(forKey: "generalShowInDock")
        let prefs = GeneralPreferences()
        #expect(prefs.showInDock == true)
    }

    @Test func `show in dock persists`() {
        let prefs = GeneralPreferences()
        defer { defaults.removeObject(forKey: "generalShowInDock") }

        prefs.showInDock = false
        let prefs2 = GeneralPreferences()
        #expect(prefs2.showInDock == false)
    }

    @Test func `launch at login unavailable in debug`() {
        let prefs = GeneralPreferences()
        #if DEBUG
            #expect(!prefs.isLaunchAtLoginAvailable)
        #endif
    }
}

// MARK: - NotificationPreferences Tests

@MainActor
struct NotificationPreferencesTests {
    @Test func `default play sounds is true`() {
        defaults.removeObject(forKey: "notificationPlaySounds")
        let prefs = NotificationPreferences()
        #expect(prefs.playNotificationSounds == true)
    }

    @Test func `default do not disturb is false`() {
        defaults.removeObject(forKey: "notificationDoNotDisturb")
        let prefs = NotificationPreferences()
        #expect(prefs.doNotDisturb == false)
    }

    @Test func `do not disturb persists`() {
        let prefs = NotificationPreferences()
        defer { defaults.removeObject(forKey: "notificationDoNotDisturb") }

        prefs.doNotDisturb = true
        let prefs2 = NotificationPreferences()
        #expect(prefs2.doNotDisturb == true)
    }
}

// MARK: - AdvancedPreferences Tests

@MainActor
struct AdvancedPreferencesTests {
    @Test func `default log level is default`() {
        defaults.removeObject(forKey: "advancedLogLevel")
        let prefs = AdvancedPreferences()
        #expect(prefs.logLevel == "default")
    }

    @Test func `log level persists`() {
        let prefs = AdvancedPreferences()
        defer { defaults.removeObject(forKey: "advancedLogLevel") }

        prefs.logLevel = "debug"
        let prefs2 = AdvancedPreferences()
        #expect(prefs2.logLevel == "debug")
    }

    @Test func `data location is valid`() {
        let prefs = AdvancedPreferences()
        let path = prefs.dataLocation.path(percentEncoded: false)
        let containsExpectedDir = path.contains("Ducko-Dev") || path.contains("Ducko")
        #expect(containsExpectedDir)
    }
}
