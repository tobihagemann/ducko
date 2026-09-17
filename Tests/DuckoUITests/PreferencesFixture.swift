import Foundation
@testable import DuckoUI

final class PreferencesFixture {
    private let suiteName = "im.ducko.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let themeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ducko-themes-\(UUID().uuidString)")

    init() {
        self.defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: themeDirectory)
    }

    @MainActor
    func makeThemeEngine(watchesUserThemes: Bool = false) -> ThemeEngine {
        ThemeEngine(defaults: defaults, userThemeDirectory: themeDirectory, watchesUserThemes: watchesUserThemes)
    }
}
