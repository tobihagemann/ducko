import Foundation
import SwiftData

@Model
final class OMEMOPreKeyRecord {
    @Attribute(.unique) var id: UUID
    var accountJID: String
    var keyID: Int64
    var keyData: Data
    var isUsed: Bool = false

    init(
        id: UUID,
        accountJID: String,
        keyID: Int64,
        keyData: Data,
        isUsed: Bool = false
    ) {
        self.id = id
        self.accountJID = accountJID
        self.keyID = keyID
        self.keyData = keyData
        self.isUsed = isUsed
    }
}
