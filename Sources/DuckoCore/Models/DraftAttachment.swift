import Foundation

public struct DraftAttachment: Sendable, Identifiable {
    public let id: UUID
    public let url: URL
    public let fileName: String
    public let fileSize: Int64
    public let mimeType: String

    public var isImage: Bool {
        mimeType.hasPrefix("image/")
    }

    public init(id: UUID = UUID(), url: URL, fileName: String, fileSize: Int64, mimeType: String) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.fileSize = fileSize
        self.mimeType = mimeType
    }
}
