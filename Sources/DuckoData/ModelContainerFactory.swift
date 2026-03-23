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
        OMEMOTrustRecord.self
    ])

    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            let storeDir = BuildEnvironment.appSupportDirectory
            try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
            let storeURL = storeDir.appendingPathComponent("default.store")
            configuration = ModelConfiguration(url: storeURL)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
