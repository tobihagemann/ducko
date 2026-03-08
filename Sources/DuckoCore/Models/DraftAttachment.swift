import Foundation

public struct DraftAttachment: Sendable, Identifiable {
    public let id: UUID
    public let url: URL
    public let fileName: String
    public let mimeType: String

    public var isImage: Bool {
        mimeType.hasPrefix("image/")
    }

    public init(id: UUID = UUID(), url: URL, fileName: String, mimeType: String) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.mimeType = mimeType
    }
}
