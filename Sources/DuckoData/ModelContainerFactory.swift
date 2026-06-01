import DuckoCore
import Foundation
import SwiftData

public enum ModelContainerFactory {
    public static let schema = Schema([
        AccountRecord.self,
        ContactRecord.self,
        ConversationRecord.self,
        LinkPreviewRecord.self,
        OMEMOIdentityRecord.self,
        OMEMOPreKeyRecord.self,
        OMEMOSignedPreKeyRecord.self,
        OMEMOSessionRecord.self,
        OMEMOTrustRecord.self,
        OMEMOSeenDeviceRecord.self
    ])

    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        if inMemory {
            return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        }
        return try makeContainer(at: BuildEnvironment.appSupportDirectory)
    }

    static func makeContainer(at storeDirectory: URL) throws -> ModelContainer {
        // Holds the SwiftData store with OMEMO key records; lock it owner-only
        // regardless of whether this or CredentialStoreFactory creates it first.
        try FileManager.default.createOwnerOnlyDirectory(at: storeDirectory)
        let storeURL = storeDirectory.appendingPathComponent("default.store")
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(url: storeURL)])
    }
}
