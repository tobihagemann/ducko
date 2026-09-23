import Foundation
import Testing
@testable import DuckoCore

/// Locks the user-visible wording for `notConnected(UUID)` across the account-scoped
/// services. CLI and UI surfaces render `error.localizedDescription`, so asserting through
/// `any Error` also catches a dropped `LocalizedError` conformance.
struct ServiceErrorDescriptionTests {
    @Test(arguments: [
        AccountService.AccountServiceError.notConnected(UUID()),
        AvatarService.AvatarServiceError.notConnected(UUID()),
        BookmarksError.notConnected(UUID()),
        ChatService.ChatServiceError.notConnected(UUID()),
        OMEMOServiceError.notConnected(UUID()),
        PresenceService.PresenceServiceError.notConnected(UUID()),
        ProfileService.ProfileServiceError.notConnected(UUID()),
        RosterService.RosterServiceError.notConnected(UUID())
    ] as [any Error])
    func `notConnected renders the shared not-connected text`(error: any Error) {
        #expect(error.localizedDescription == "Not connected to the server")
    }
}
