import Foundation
import DuckoCore

extension AttachmentRecord {
    func toDomain() -> Attachment? {
        guard let messageID = message?.id else { return nil }
        return Attachment(
            id: id,
            messageID: messageID,
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

    func update(from attachment: Attachment) {
        url = attachment.url
        mimeType = attachment.mimeType
        fileName = attachment.fileName
        fileSize = attachment.fileSize
        width = attachment.width
        height = attachment.height
        thumbnailData = attachment.thumbnailData
        localPath = attachment.localPath
    }
}
