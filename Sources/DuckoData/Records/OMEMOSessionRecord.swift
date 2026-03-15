import Foundation
import SwiftData

@Model
final class OMEMOSessionRecord {
    @Attribute(.unique) var id: UUID
    var accountJID: String
    var peerJID: String
    var peerDeviceID: Int64
    var sessionData: Data
    var associatedData: Data
    var updatedAt: Date = Date()

    init(
        id: UUID,
        accountJID: String,
        peerJID: String,
        peerDeviceID: Int64,
        sessionData: Data,
        associatedData: Data,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.accountJID = accountJID
        self.peerJID = peerJID
        self.peerDeviceID = peerDeviceID
        self.sessionData = sessionData
        self.associatedData = associatedData
        self.updatedAt = updatedAt
    }
}
