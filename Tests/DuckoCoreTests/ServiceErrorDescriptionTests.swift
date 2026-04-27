import Foundation
import Testing
@testable import DuckoCore

/// Locks the user-visible wording for `notConnected(UUID)` across the
/// account-scoped services that migrated together. CLI and UI surfaces
/// render `error.localizedDescription`, which goes through the
/// `LocalizedError` bridge — asserting via `(error as Error)` so a
/// future drop of `LocalizedError` conformance (which would break the
/// bridge while leaving `errorDescription` intact) is caught.
struct ServiceErrorDescriptionTests {
    @Test func `BookmarksError.notConnected description embeds account UUID`() {
        let id = UUID()
        let error: any Error = BookmarksError.notConnected(id)
        #expect(error.localizedDescription == "Not connected: \(id)")
    }

    @Test func `OMEMOServiceError.notConnected description embeds account UUID`() {
        let id = UUID()
        let error: any Error = OMEMOServiceError.notConnected(id)
        #expect(error.localizedDescription == "Not connected: \(id)")
    }

    @Test func `ProfileService.ProfileServiceError.notConnected description embeds account UUID`() {
        let id = UUID()
        let error: any Error = ProfileService.ProfileServiceError.notConnected(id)
        #expect(error.localizedDescription == "Not connected: \(id)")
    }
}
