import DuckoCore
import Foundation
import SwiftUI

@MainActor @Observable
final class NotificationPreferences {
    private enum Keys {
        static let playNotificationSounds = "notificationPlaySounds"
        static let doNotDisturb = "notificationDoNotDisturb"
    }

    var playNotificationSounds: Bool {
        didSet { playNotificationSoundsStorage = playNotificationSounds }
    }

    var doNotDisturb: Bool {
        didSet { doNotDisturbStorage = doNotDisturb }
    }

    @ObservationIgnored
    @AppStorage(Keys.playNotificationSounds) private var playNotificationSoundsStorage = true

    @ObservationIgnored
    @AppStorage(Keys.doNotDisturb) private var doNotDisturbStorage = false

    init(defaults: UserDefaults = PreferencesDefaults.store) {
        _playNotificationSoundsStorage = AppStorage(wrappedValue: true, Keys.playNotificationSounds, store: defaults)
        _doNotDisturbStorage = AppStorage(wrappedValue: false, Keys.doNotDisturb, store: defaults)
        self.playNotificationSounds = defaults.object(forKey: Keys.playNotificationSounds) as? Bool ?? true
        self.doNotDisturb = defaults.bool(forKey: Keys.doNotDisturb)
    }
}
