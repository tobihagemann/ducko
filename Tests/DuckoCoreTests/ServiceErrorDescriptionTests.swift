import Foundation
import Testing
@testable import DuckoCore

/// Locks the user-visible wording for `notConnected(UUID)` across the eight
/// account-scoped services that share `notConnectedDescription`. CLI and UI
/// surfaces render `error.localizedDescription`, which goes through the
/// `LocalizedError` bridge — asserting via `(error as Error)` so a future
/// drop of `LocalizedError` conformance (which would break the bridge while
/// leaving `errorDescription` intact) is caught. The other arms on each enum
/// (`invalidJID`, `accountNotFound`, `noStoredPassword`, `moduleNotAvailable`,
/// etc.) are intentionally NOT covered here — this file is scoped to the
/// shared-wording invariant.
struct ServiceErrorDescriptionTests {
    @Test func `AccountService.AccountServiceError.notConnected description embeds account UUID`() {
        let id = UUID()
        let error: any Error = AccountService.AccountServiceError.notConnected(id)
        #expect(error.localizedDescription == "Not connected: \(id)")
    }

    @Test func `AvatarService.AvatarServiceError.notConnected description embeds account UUID`() {
        let id = UUID()
        let error: any Error = AvatarService.AvatarServiceError.notConnected(id)
        #expect(error.localizedDescription == "Not connected: \(id)")
    }

    @Test func `BookmarksError.notConnected description embeds account UUID`() {
        let id = UUID()
        let error: any Error = BookmarksError.notConnected(id)
        #expect(error.localizedDescription == "Not connected: \(id)")
    }

    @Test func `ChatService.ChatServiceError.notConnected description embeds account UUID`() {
        let id = UUID()
        let error: any Error = ChatService.ChatServiceError.notConnected(id)
        #expect(error.localizedDescription == "Not connected: \(id)")
    }

    @Test func `OMEMOServiceError.notConnected description embeds account UUID`() {
        let id = UUID()
        let error: any Error = OMEMOServiceError.notConnected(id)
        #expect(error.localizedDescription == "Not connected: \(id)")
    }

    @Test func `PresenceService.PresenceServiceError.notConnected description embeds account UUID`() {
        let id = UUID()
        let error: any Error = PresenceService.PresenceServiceError.notConnected(id)
        #expect(error.localizedDescription == "Not connected: \(id)")
    }

    @Test func `ProfileService.ProfileServiceError.notConnected description embeds account UUID`() {
        let id = UUID()
        let error: any Error = ProfileService.ProfileServiceError.notConnected(id)
        #expect(error.localizedDescription == "Not connected: \(id)")
    }

    @Test func `RosterService.RosterServiceError.notConnected description embeds account UUID`() {
        let id = UUID()
        let error: any Error = RosterService.RosterServiceError.notConnected(id)
        #expect(error.localizedDescription == "Not connected: \(id)")
    }
}
