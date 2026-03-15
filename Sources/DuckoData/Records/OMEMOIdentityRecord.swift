import Foundation
import SwiftData

@Model
final class OMEMOIdentityRecord {
    @Attribute(.unique) var id: UUID
    var accountJID: String
    var deviceID: Int64
    var identityKeyData: Data
    var registrationID: Int64
    var createdAt: Date = Date()

    init(
        id: UUID,
        accountJID: String,
        deviceID: Int64,
        identityKeyData: Data,
        registrationID: Int64,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.accountJID = accountJID
        self.deviceID = deviceID
        self.identityKeyData = identityKeyData
        self.registrationID = registrationID
        self.createdAt = createdAt
    }
}
