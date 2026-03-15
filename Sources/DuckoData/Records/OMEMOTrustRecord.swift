import Foundation
import SwiftData

@Model
final class OMEMOTrustRecord {
    @Attribute(.unique) var id: UUID
    var accountJID: String
    var peerJID: String
    var deviceID: Int64
    var fingerprint: String
    var trustLevel: String = "undecided"

    init(
        id: UUID,
        accountJID: String,
        peerJID: String,
        deviceID: Int64,
        fingerprint: String,
        trustLevel: String = "undecided"
    ) {
        self.id = id
        self.accountJID = accountJID
        self.peerJID = peerJID
        self.deviceID = deviceID
        self.fingerprint = fingerprint
        self.trustLevel = trustLevel
    }
}
