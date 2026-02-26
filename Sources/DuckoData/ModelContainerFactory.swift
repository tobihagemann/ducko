import Foundation
import SwiftData

public enum ModelContainerFactory {
    public static let schema = Schema([
        AccountRecord.self,
        ContactRecord.self,
        ConversationRecord.self,
        MessageRecord.self,
        AttachmentRecord.self,
        LinkPreviewRecord.self,
    ])

    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
