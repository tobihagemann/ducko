import DuckoCore
import Testing
@testable import DuckoUI

struct StatusToggleActionTests {
    @Test(arguments: PresenceService.PresenceStatus.allCases)
    func `each status resolves to its toggle action`(_ status: PresenceService.PresenceStatus) {
        let action = StatusToggleAction.resolve(current: status, savedAwayMessages: ["Lunch", "Errand"])

        switch status {
        case .available: #expect(action == .customAway(message: "Lunch"))
        case .away, .xa, .dnd, .offline: #expect(action == .setAvailable)
        }
    }

    @Test func `available with no saved away message presets an empty message`() {
        #expect(StatusToggleAction.resolve(current: .available, savedAwayMessages: []) == .customAway(message: ""))
    }
}
