import DuckoCore
import Foundation
import Testing
@testable import DuckoUI

private nonisolated(unsafe) let defaults = PreferencesDefaults.store

// MARK: - GeneralPreferences Tests

@MainActor
struct GeneralPreferencesTests {
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
    @Test func `default log level is standard`() {
        defaults.removeObject(forKey: LogLevelPreference.userDefaultsKey)
        let prefs = AdvancedPreferences()
        #expect(prefs.logLevel == .standard)
    }

    @Test func `log level persists`() {
        let prefs = AdvancedPreferences()
        defer { defaults.removeObject(forKey: LogLevelPreference.userDefaultsKey) }

        prefs.logLevel = .debug
        let prefs2 = AdvancedPreferences()
        #expect(prefs2.logLevel == .debug)
        #expect(defaults.string(forKey: LogLevelPreference.userDefaultsKey) == "debug")
    }

    @Test func `data location is valid`() {
        let prefs = AdvancedPreferences()
        let path = prefs.dataLocation.path(percentEncoded: false)
        let containsExpectedDir = path.contains("Ducko-Dev") || path.contains("Ducko")
        #expect(containsExpectedDir)
    }
}
