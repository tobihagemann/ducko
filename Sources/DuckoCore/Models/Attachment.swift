import Foundation

public struct Attachment: Sendable, Identifiable {
    public var id: UUID
    public var messageID: UUID
    public var url: String
    public var mimeType: String?
    public var fileName: String?
    public var fileSize: Int64?
    public var width: Int?
    public var height: Int?
    public var thumbnailData: Data?
    public var localPath: String?

    public init(
        id: UUID,
        messageID: UUID,
        url: String,
        mimeType: String? = nil,
        fileName: String? = nil,
        fileSize: Int64? = nil,
        width: Int? = nil,
        height: Int? = nil,
        thumbnailData: Data? = nil,
        localPath: String? = nil
    ) {
        self.id = id
        self.messageID = messageID
        self.url = url
        self.mimeType = mimeType
        self.fileName = fileName
        self.fileSize = fileSize
        self.width = width
        self.height = height
        self.thumbnailData = thumbnailData
        self.localPath = localPath
    }

    // MARK: - Computed Helpers

    public var isImage: Bool {
        mimeType?.hasPrefix("image/") == true
    }

    public var displayFileName: String {
        if let fileName, !fileName.isEmpty {
            return fileName
        }
        return URL(string: url)?.lastPathComponent ?? url
    }

    public var formattedFileSize: String? {
        guard let fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}
