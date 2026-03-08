import Foundation
import Testing
@testable import DuckoCore

enum AttachmentModelTests {
    private static func makeAttachment(
        url: String = "https://example.com/file.txt",
        mimeType: String? = nil,
        fileName: String? = nil,
        fileSize: Int64? = nil
    ) -> DuckoCore.Attachment {
        DuckoCore.Attachment(
            id: UUID(),
            url: url,
            mimeType: mimeType,
            fileName: fileName,
            fileSize: fileSize
        )
    }

    struct IsImage {
        @Test
        func `Returns true for image MIME types`() {
            let png = makeAttachment(mimeType: "image/png")
            let jpeg = makeAttachment(mimeType: "image/jpeg")
            let gif = makeAttachment(mimeType: "image/gif")

            #expect(png.isImage)
            #expect(jpeg.isImage)
            #expect(gif.isImage)
        }

        @Test
        func `Returns false for non-image MIME types`() {
            let pdf = makeAttachment(mimeType: "application/pdf")
            let text = makeAttachment(mimeType: "text/plain")

            #expect(!pdf.isImage)
            #expect(!text.isImage)
        }

        @Test
        func `Returns false when MIME type is nil`() {
            let attachment = makeAttachment(mimeType: nil)
            #expect(!attachment.isImage)
        }
    }

    struct DisplayFileName {
        @Test
        func `Returns fileName when set`() {
            let attachment = makeAttachment(fileName: "report.pdf")
            #expect(attachment.displayFileName == "report.pdf")
        }

        @Test
        func `Falls back to URL last path component`() {
            let attachment = makeAttachment(url: "https://example.com/files/photo.jpg", fileName: nil)
            #expect(attachment.displayFileName == "photo.jpg")
        }

        @Test
        func `Falls back to URL when empty fileName`() {
            let attachment = makeAttachment(url: "https://example.com/document.pdf", fileName: "")
            #expect(attachment.displayFileName == "document.pdf")
        }
    }

    struct FormattedFileSize {
        @Test
        func `Returns nil when fileSize is nil`() {
            let noSize: Int64? = nil
            let attachment = makeAttachment(fileSize: noSize)
            #expect(attachment.formattedFileSize == nil)
        }

        @Test
        func `Returns formatted string for known sizes`() {
            let attachment = makeAttachment(fileSize: 5_242_880) // 5 MB
            let result = attachment.formattedFileSize
            #expect(result != nil)
            let resultContainsMB = result?.contains("MB") == true
            #expect(resultContainsMB)
        }

        @Test
        func `Returns formatted string for zero bytes`() {
            let attachment = makeAttachment(fileSize: 0)
            let result = attachment.formattedFileSize
            #expect(result != nil)
        }
    }

    struct ChatMessageAttachments {
        @Test
        func `ChatMessage defaults to empty attachments`() {
            let message = ChatMessage(
                id: UUID(),
                conversationID: UUID(),
                fromJID: "user@example.com",
                body: "Hello",
                timestamp: Date(),
                isOutgoing: false,
                isRead: false,
                isDelivered: false,
                isEdited: false,
                type: "chat"
            )
            #expect(message.attachments.isEmpty)
        }

        @Test
        func `ChatMessage can be created with attachments`() {
            let attachment = makeAttachment(mimeType: "image/png")
            let message = ChatMessage(
                id: UUID(),
                conversationID: UUID(),
                fromJID: "user@example.com",
                body: "",
                timestamp: Date(),
                isOutgoing: false,
                isRead: false,
                isDelivered: false,
                isEdited: false,
                type: "chat",
                attachments: [attachment]
            )
            #expect(message.attachments.count == 1)
            #expect(message.attachments[0].isImage)
        }
    }
}
