import Foundation
import SwiftUI

@MainActor @Observable
final class NotificationPreferences {
    private enum Keys {
        static let playNotificationSounds = "notificationPlaySounds"
        static let doNotDisturb = "notificationDoNotDisturb"
    }

    private static let defaults = PreferencesDefaults.store

    var playNotificationSounds: Bool {
        didSet { playNotificationSoundsStorage = playNotificationSounds }
    }

    var doNotDisturb: Bool {
        didSet { doNotDisturbStorage = doNotDisturb }
    }

    @ObservationIgnored
    @AppStorage(Keys.playNotificationSounds, store: NotificationPreferences.defaults) private var playNotificationSoundsStorage = true

    @ObservationIgnored
    @AppStorage(Keys.doNotDisturb, store: NotificationPreferences.defaults) private var doNotDisturbStorage = false

    init() {
        self.playNotificationSounds = NotificationPreferences.defaults.object(forKey: Keys.playNotificationSounds) as? Bool ?? true
        self.doNotDisturb = NotificationPreferences.defaults.bool(forKey: Keys.doNotDisturb)
    }
}
