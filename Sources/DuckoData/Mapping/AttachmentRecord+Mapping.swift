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
            width: width,
            height: height,
            thumbnailData: thumbnailData,
            localPath: localPath
        )
    }
}
