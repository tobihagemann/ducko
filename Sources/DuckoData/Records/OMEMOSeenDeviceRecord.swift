import Foundation
import SwiftData

@Model
final class OMEMOSeenDeviceRecord {
    @Attribute(.unique) var id: UUID
    var accountJID: String
    /// `UInt32` stored as `Int64` to match the precedent in
    /// `OMEMOTrustRecord` and `OMEMOSessionRecord` (SwiftData has no native
    /// `UInt32` column type).
    var deviceID: Int64
    var classification: String
    var staleStreak: Int = 0
    var hasObservedHealthy: Bool = false

    init(
        id: UUID,
        accountJID: String,
        deviceID: Int64,
        classification: String,
        staleStreak: Int,
        hasObservedHealthy: Bool
    ) {
        self.id = id
        self.accountJID = accountJID
        self.deviceID = deviceID
        self.classification = classification
        self.staleStreak = staleStreak
        self.hasObservedHealthy = hasObservedHealthy
    }
}
