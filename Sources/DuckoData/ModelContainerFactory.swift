import Foundation
import SwiftData

public enum ModelContainerFactory {
    public static let schema = Schema([
        AccountRecord.self,
        ContactRecord.self,
        ConversationRecord.self,
        MessageRecord.self,
        AttachmentRecord.self,
        LinkPreviewRecord.self
    ])

    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let storeDir = appSupport.appendingPathComponent("Ducko", isDirectory: true)
            try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
            let storeURL = storeDir.appendingPathComponent("default.store")
            configuration = ModelConfiguration(url: storeURL)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
