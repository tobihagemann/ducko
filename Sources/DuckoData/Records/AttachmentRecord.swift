import Foundation
import SwiftData

@Model
final class AttachmentRecord {
    @Attribute(.unique) var id: UUID
    var url: String
    var mimeType: String?
    var fileName: String?
    var fileSize: Int64?
    @Attribute(.externalStorage) var thumbnailData: Data?
    // Retained for schema compatibility — no longer mapped to domain model
    var width: Int?
    var height: Int?
    var localPath: String?
    var message: MessageRecord?

    // periphery:ignore
    init(
        id: UUID,
        url: String,
        mimeType: String? = nil,
        fileName: String? = nil,
        fileSize: Int64? = nil,
        width: Int? = nil,
        height: Int? = nil,
        thumbnailData: Data? = nil,
        localPath: String? = nil,
        message: MessageRecord? = nil
    ) {
        self.id = id
        self.url = url
        self.mimeType = mimeType
        self.fileName = fileName
        self.fileSize = fileSize
        self.width = width
        self.height = height
        self.thumbnailData = thumbnailData
        self.localPath = localPath
        self.message = message
    }
}
