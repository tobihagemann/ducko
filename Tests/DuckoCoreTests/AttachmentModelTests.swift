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
            messageID: UUID(),
            url: url,
            mimeType: mimeType,
            fileName: fileName,
            fileSize: fileSize
        )
    }

    struct IsImage {
        @Test("Returns true for image MIME types")
        func imageTypes() {
            let png = makeAttachment(mimeType: "image/png")
            let jpeg = makeAttachment(mimeType: "image/jpeg")
            let gif = makeAttachment(mimeType: "image/gif")

            #expect(png.isImage)
            #expect(jpeg.isImage)
            #expect(gif.isImage)
        }

        @Test("Returns false for non-image MIME types")
        func nonImageTypes() {
            let pdf = makeAttachment(mimeType: "application/pdf")
            let text = makeAttachment(mimeType: "text/plain")

            #expect(!pdf.isImage)
            #expect(!text.isImage)
        }

        @Test("Returns false when MIME type is nil")
        func nilMimeType() {
            let attachment = makeAttachment(mimeType: nil)
            #expect(!attachment.isImage)
        }
    }

    struct DisplayFileName {
        @Test("Returns fileName when set")
        func usesFileName() {
            let attachment = makeAttachment(fileName: "report.pdf")
            #expect(attachment.displayFileName == "report.pdf")
        }

        @Test("Falls back to URL last path component")
        func fallsBackToURL() {
            let attachment = makeAttachment(url: "https://example.com/files/photo.jpg", fileName: nil)
            #expect(attachment.displayFileName == "photo.jpg")
        }

        @Test("Falls back to URL when empty fileName")
        func emptyFileName() {
            let attachment = makeAttachment(url: "https://example.com/document.pdf", fileName: "")
            #expect(attachment.displayFileName == "document.pdf")
        }
    }

    struct FormattedFileSize {
        @Test("Returns nil when fileSize is nil")
        func nilSize() {
            let noSize: Int64? = nil
            let attachment = makeAttachment(fileSize: noSize)
            #expect(attachment.formattedFileSize == nil)
        }

        @Test("Returns formatted string for known sizes")
        func formatsSize() {
            let attachment = makeAttachment(fileSize: 5_242_880) // 5 MB
            let result = attachment.formattedFileSize
            #expect(result != nil)
            let resultContainsMB = result?.contains("MB") == true
            #expect(resultContainsMB)
        }

        @Test("Returns formatted string for zero bytes")
        func zeroBytes() {
            let attachment = makeAttachment(fileSize: 0)
            let result = attachment.formattedFileSize
            #expect(result != nil)
        }
    }

    struct ChatMessageAttachments {
        @Test("ChatMessage defaults to empty attachments")
        func defaultEmpty() {
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

        @Test("ChatMessage can be created with attachments")
        func withAttachments() {
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
