import Sparkle

@Observable
@MainActor
final class UpdateManager {
    /// Sparkle crashes when running via `swift run` (no app bundle).
    /// Guard with bundle check — same pattern as NotificationManager.
    private let controller: SPUStandardUpdaterController? = {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }()

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
