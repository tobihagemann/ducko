import DuckoCore

/// What the Status menu's ⌘Y item does. From Available it opens the Custom Status sheet preset to Away with the
/// latest saved Away message. From any other status it returns to Available.
enum StatusToggleAction: Equatable {
    case setAvailable
    case customAway(message: String)

    static func resolve(current: PresenceService.PresenceStatus, savedAwayMessages: [String]) -> StatusToggleAction {
        switch current {
        case .available: .customAway(message: savedAwayMessages.first ?? "")
        case .away, .xa, .dnd, .offline: .setAvailable
        }
    }
}
