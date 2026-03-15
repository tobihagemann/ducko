import Foundation
import SwiftData

@Model
final class OMEMOSignedPreKeyRecord {
    @Attribute(.unique) var id: UUID
    var accountJID: String
    var keyID: Int64
    var keyData: Data
    var signature: Data
    var timestamp: Date = Date()

    init(
        id: UUID,
        accountJID: String,
        keyID: Int64,
        keyData: Data,
        signature: Data,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.accountJID = accountJID
        self.keyID = keyID
        self.keyData = keyData
        self.signature = signature
        self.timestamp = timestamp
    }
}
