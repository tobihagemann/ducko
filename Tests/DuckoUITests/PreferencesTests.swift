import DuckoCore
import Foundation
import Testing
@testable import DuckoUI

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
    @Test func `sound and notification writes stay in the supplied store`() {
        let fixture = PreferencesFixture()
        let other = PreferencesFixture()
        let prefs = NotificationPreferences(defaults: fixture.defaults)
        prefs.playNotificationSounds = false
        prefs.doNotDisturb = true
        #expect(fixture.defaults.bool(forKey: "notificationPlaySounds") == false)
        #expect(fixture.defaults.bool(forKey: "notificationDoNotDisturb") == true)
        #expect(NotificationPreferences(defaults: fixture.defaults).playNotificationSounds == false)
        #expect(NotificationPreferences(defaults: other.defaults).playNotificationSounds == true)
        #expect(NotificationPreferences(defaults: other.defaults).doNotDisturb == false)
    }

    @Test func `default play sounds is true`() {
        let fixture = PreferencesFixture()
        let prefs = NotificationPreferences(defaults: fixture.defaults)
        #expect(prefs.playNotificationSounds == true)
    }

    @Test func `default do not disturb is false`() {
        let fixture = PreferencesFixture()
        let prefs = NotificationPreferences(defaults: fixture.defaults)
        #expect(prefs.doNotDisturb == false)
    }

    @Test func `do not disturb persists`() {
        let fixture = PreferencesFixture()
        let prefs = NotificationPreferences(defaults: fixture.defaults)

        prefs.doNotDisturb = true
        let prefs2 = NotificationPreferences(defaults: fixture.defaults)
        #expect(prefs2.doNotDisturb == true)
    }
}

// MARK: - AdvancedPreferences Tests

@MainActor
struct AdvancedPreferencesTests {
    @Test func `default log level is standard`() {
        let fixture = PreferencesFixture()
        let prefs = AdvancedPreferences(defaults: fixture.defaults)
        #expect(prefs.logLevel == .standard)
    }

    @Test func `log level persists`() {
        let fixture = PreferencesFixture()
        let prefs = AdvancedPreferences(defaults: fixture.defaults)

        prefs.logLevel = .debug
        let prefs2 = AdvancedPreferences(defaults: fixture.defaults)
        #expect(prefs2.logLevel == .debug)
        #expect(fixture.defaults.string(forKey: LogLevelPreference.userDefaultsKey) == "debug")
        #expect(AdvancedPreferences(defaults: PreferencesFixture().defaults).logLevel == .standard)
    }

    @Test func `data location is valid`() {
        let fixture = PreferencesFixture()
        let prefs = AdvancedPreferences(defaults: fixture.defaults)
        let path = prefs.dataLocation.path(percentEncoded: false)
        let containsExpectedDir = path.contains("Ducko-Dev") || path.contains("Ducko")
        #expect(containsExpectedDir)
    }
}
