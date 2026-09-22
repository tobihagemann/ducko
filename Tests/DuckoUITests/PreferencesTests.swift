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
