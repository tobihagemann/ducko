import Logging
import Testing
@testable import DuckoCore

@Suite(.serialized)
struct LoggingConfigurationTests {
    private static let key = "advancedLogLevel"

    @Test
    func `fileLogLevel returns info for default`() {
        PreferencesDefaults.store.set("default", forKey: Self.key)
        defer { PreferencesDefaults.store.removeObject(forKey: Self.key) }
        #expect(LoggingConfiguration.fileLogLevel == .info)
    }

    @Test
    func `fileLogLevel returns debug for debug`() {
        PreferencesDefaults.store.set("debug", forKey: Self.key)
        defer { PreferencesDefaults.store.removeObject(forKey: Self.key) }
        #expect(LoggingConfiguration.fileLogLevel == .debug)
    }

    @Test
    func `fileLogLevel returns trace for verbose`() {
        PreferencesDefaults.store.set("verbose", forKey: Self.key)
        defer { PreferencesDefaults.store.removeObject(forKey: Self.key) }
        #expect(LoggingConfiguration.fileLogLevel == .trace)
    }

    @Test
    func `fileLogLevel returns info for nil`() {
        PreferencesDefaults.store.removeObject(forKey: Self.key)
        #expect(LoggingConfiguration.fileLogLevel == .info)
    }
}
