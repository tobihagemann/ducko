import Foundation

/// Standard "Not connected: <accountID>" message shared by every service's `notConnected(UUID)` `errorDescription`.
/// Centralized so `ServiceErrorDescriptionTests` stay in sync. Free function (not a protocol) because the error enums have mixed access levels.
package func notConnectedDescription(_ accountID: UUID) -> String {
    "Not connected: \(accountID)"
}
