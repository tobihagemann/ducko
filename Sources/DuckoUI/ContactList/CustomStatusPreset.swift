import DuckoCore
import Foundation

/// The presence and message the Custom Status sheet opens with.
struct CustomStatusPreset: Identifiable, Hashable {
    let id = UUID()
    let presence: PresenceService.PresenceStatus
    let message: String

    /// Offline has no custom message and the sheet's picker offers only selectable presences, so it presets Available.
    init(presence: PresenceService.PresenceStatus, message: String) {
        self.presence = presence == .offline ? .available : presence
        self.message = message
    }
}
