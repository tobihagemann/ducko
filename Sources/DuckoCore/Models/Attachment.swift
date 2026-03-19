import Foundation

public struct Attachment: Sendable, Identifiable {
    public var id: UUID
    public var url: String
    public var mimeType: String?
    public var fileName: String?
    public var fileSize: Int64?
    public var thumbnailData: Data?
    public var oobDescription: String?

    public init(
        id: UUID,
        url: String,
        mimeType: String? = nil,
        fileName: String? = nil,
        fileSize: Int64? = nil,
        thumbnailData: Data? = nil,
        oobDescription: String? = nil
    ) {
        self.id = id
        self.url = url
        self.mimeType = mimeType
        self.fileName = fileName
        self.fileSize = fileSize
        self.thumbnailData = thumbnailData
        self.oobDescription = oobDescription
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
