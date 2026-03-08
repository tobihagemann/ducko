import DuckoCore
import Foundation
import SwiftUI

@MainActor @Observable
public final class ThemeEngine {
    private enum Keys {
        static let selectedThemeID = "selectedThemeID"
    }

    private static let defaultThemeID = "default"

    @ObservationIgnored
    private static let defaults: UserDefaults = {
        if let suite = BuildEnvironment.userDefaultsSuiteName {
            return UserDefaults(suiteName: suite) ?? .standard
        }
        return .standard
    }()

    @ObservationIgnored
    private var builtInThemes: [DuckoTheme] = []
    @ObservationIgnored
    private var fileWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored
    private var debounceTask: Task<Void, Never>?
    public private(set) var availableThemes: [DuckoTheme] = []
    public private(set) var current: DuckoTheme

    public init() {
        let builtIn = ThemeEngine.loadBuiltInThemes()
        let userThemes = ThemeEngine.loadUserThemes()
        let all = builtIn + userThemes
        precondition(!all.isEmpty, "No themes found — built-in theme bundle is missing")
        self.builtInThemes = builtIn
        self.availableThemes = all

        let savedID = ThemeEngine.defaults.string(forKey: Keys.selectedThemeID)
        self.current = all.first { $0.id == savedID } ?? all.first { $0.id == ThemeEngine.defaultThemeID } ?? all[0]

        startWatchingUserThemes()
    }

    deinit {
        debounceTask?.cancel()
        fileWatcher?.cancel()
    }

    public func selectTheme(_ theme: DuckoTheme) {
        current = theme
        ThemeEngine.defaults.set(theme.id, forKey: Keys.selectedThemeID)
    }

    public func reloadUserThemes() {
        let userThemes = ThemeEngine.loadUserThemes()
        availableThemes = builtInThemes + userThemes

        if let updated = availableThemes.first(where: { $0.id == current.id }) {
            current = updated
        } else {
            guard let first = availableThemes.first else { return }
            current = availableThemes.first { $0.id == ThemeEngine.defaultThemeID } ?? first
        }
    }

    // MARK: - Convenience

    public func bubbleColor(isOutgoing: Bool, colorScheme: ColorScheme) -> Color {
        if isOutgoing {
            return current.outgoingBubbleColor.resolved(for: colorScheme)
        }
        return current.incomingBubbleColor.resolved(for: colorScheme)
    }

    public func textColor(isOutgoing: Bool, colorScheme: ColorScheme) -> Color {
        if isOutgoing {
            return current.outgoingTextColor.resolved(for: colorScheme)
        }
        return current.incomingTextColor.resolved(for: colorScheme)
    }

    // MARK: - Private

    private func startWatchingUserThemes() {
        let themesDir = BuildEnvironment.appSupportDirectory.appendingPathComponent("Themes", isDirectory: true)
        try? FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)

        let fd = open(themesDir.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.debounceTask?.cancel()
            self?.debounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.reloadUserThemes()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        fileWatcher = source
    }

    private static func loadBuiltInThemes() -> [DuckoTheme] {
        guard let themesURL = Bundle.module.url(forResource: "Themes", withExtension: nil) else {
            return []
        }
        return loadThemes(from: themesURL)
    }

    private static func loadUserThemes() -> [DuckoTheme] {
        let userThemesDir = BuildEnvironment.appSupportDirectory.appendingPathComponent("Themes", isDirectory: true)
        return loadThemes(from: userThemesDir)
    }

    private static func loadThemes(from directory: URL) -> [DuckoTheme] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(DuckoTheme.self, from: data)
            }
    }
}
