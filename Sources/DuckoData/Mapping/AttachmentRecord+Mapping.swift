import DuckoCore
import Foundation

extension AttachmentRecord {
    func toDomain() -> Attachment {
        Attachment(
            id: id,
            url: url,
            mimeType: mimeType,
            fileName: fileName,
            fileSize: fileSize,
            thumbnailData: thumbnailData
        )
    }
}
