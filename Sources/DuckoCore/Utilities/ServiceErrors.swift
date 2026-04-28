import Foundation

/// Builds the standard "Not connected: <accountID>" message embedded in every
/// service-scoped `notConnected(UUID)` `errorDescription`. Centralized in one
/// place so the eight services that share the wording (`AccountService`,
/// `AvatarService`, `BookmarksService`, `ChatService`, `OMEMOService`,
/// `PresenceService`, `ProfileService`, `RosterService`) can never drift out
/// of sync with each other or with `ServiceErrorDescriptionTests`. A free
/// function rather than a marker protocol because the eight error enums have
/// inconsistent access levels (six nested `public`, two file-scope
/// `internal`) — protocol conformance would force a uniformity those enums
/// don't share.
package func notConnectedDescription(_ accountID: UUID) -> String {
    "Not connected: \(accountID)"
}
