import Foundation
import Logging
import Testing
@testable import DuckoCore

struct LoggingConfigurationTests {
    @Test(arguments: [
        ("default", Logger.Level.info),
        ("debug", Logger.Level.debug),
        ("verbose", Logger.Level.trace),
        ("chatty", Logger.Level.info)
    ])
    func `log level maps the supplied store dynamically`(raw: String, expected: Logger.Level) throws {
        let suiteName = "im.ducko.logging-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(LoggingConfiguration.fileLogLevel(from: defaults) == .info)
        defaults.set(raw, forKey: LogLevelPreference.userDefaultsKey)
        #expect(LoggingConfiguration.fileLogLevel(from: defaults) == expected)
        defaults.set("verbose", forKey: LogLevelPreference.userDefaultsKey)
        #expect(LogLevelPreference.read(from: defaults) == .verbose)
        #expect(LoggingConfiguration.fileLogLevel(from: defaults) == .trace)
        defaults.removeObject(forKey: LogLevelPreference.userDefaultsKey)
        #expect(LogLevelPreference.read(from: defaults) == .standard)
        #expect(LoggingConfiguration.fileLogLevel(from: defaults) == .info)
    }

    @Test func `log preferences are isolated between stores`() throws {
        let firstName = "im.ducko.logging-tests.\(UUID().uuidString)"
        let secondName = "im.ducko.logging-tests.\(UUID().uuidString)"
        let first = try #require(UserDefaults(suiteName: firstName))
        let second = try #require(UserDefaults(suiteName: secondName))
        defer {
            first.removePersistentDomain(forName: firstName)
            second.removePersistentDomain(forName: secondName)
        }
        first.set("debug", forKey: LogLevelPreference.userDefaultsKey)
        #expect(LoggingConfiguration.fileLogLevel(from: first) == .debug)
        #expect(LoggingConfiguration.fileLogLevel(from: second) == .info)
    }
}
