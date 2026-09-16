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

        /// A peer's name, given outright or taken from its link, is shown the way an offered file's name is, so a
        /// direction override cannot make `invoice‮fdp.exe` read as `invoiceexe.pdf`.
        @Test(arguments: [
            (nil, "https://example.com/invoice%E2%80%AEfdp.exe"),
            ("invoice\u{202E}fdp.exe", "https://example.com/x")
        ])
        func `A peer's file name is reduced to one visible name`(fileName: String?, url: String) {
            let attachment = makeAttachment(url: url, fileName: fileName)
            #expect(attachment.displayFileName == "invoicefdp.exe")
        }

        /// This app named a file it saved itself, so that name is shown as it is.
        @Test
        func `A saved file keeps its own name`() {
            let fileURL = URL(filePath: "/tmp/notes: draft.txt")
            let attachment = DuckoCore.Attachment.locallySaved(id: UUID(), fileURL: fileURL)
            #expect(attachment.displayFileName == "notes: draft.txt")
        }
    }

    struct LocalFileURL {
        @Test
        func `A file this app saved is its own file`() {
            let saved = Attachment.locallySaved(id: UUID(), fileURL: URL(fileURLWithPath: "/Users/me/Downloads/photo.png"))
            #expect(saved.localFileURL?.path == "/Users/me/Downloads/photo.png")
            #expect(saved.origin == .locallySaved)
        }

        /// The defect this guards: a peer sends `file:///Users/me/Documents/tax-return.pdf` and the bubble offers to
        /// preview and reveal the recipient's own document. The scheme is identical to the one above, so only
        /// provenance separates them.
        @Test(arguments: [
            "file:///Users/me/Documents/tax-return.pdf",
            "file:///etc/passwd",
            "https://example.com/photo.png",
            "mailto:someone@example.com"
        ])
        func `Anything this app did not save has no local file`(url: String) {
            let attachment = makeAttachment(url: url)
            #expect(attachment.origin == .remote)
            #expect(attachment.localFileURL == nil)
        }

        /// Records written before provenance was stored carry no origin at all, and must decode as the safe reading
        /// rather than as a file this app can be talked into opening.
        @Test
        func `A record stored before provenance existed decodes as remote`() throws {
            let legacy = Data(#"{"id":"\#(UUID().uuidString)","url":"file:///Users/me/Documents/tax-return.pdf"}"#.utf8)
            let decoded = try JSONDecoder().decode(Attachment.self, from: legacy)
            #expect(decoded.origin == .remote)
            #expect(decoded.localFileURL == nil)
        }

        /// A saved attachment has to survive the transcript round trip, or preview and reveal break on relaunch.
        @Test
        func `A saved file keeps its provenance across a round trip`() throws {
            let saved = Attachment.locallySaved(id: UUID(), fileURL: URL(fileURLWithPath: "/Users/me/Downloads/photo.png"))
            let decoded = try JSONDecoder().decode(Attachment.self, from: JSONEncoder().encode(saved))
            #expect(decoded.origin == .locallySaved)
            #expect(decoded.localFileURL?.path == "/Users/me/Downloads/photo.png")
        }
    }

    struct RemoteURL {
        @Test(arguments: ["https://example.com/photo.png", "http://example.com/photo.png"])
        func `A web address is the attachment's remote URL`(url: String) {
            #expect(makeAttachment(url: url).remoteURL?.absoluteString == url)
        }

        /// Everything a peer could put in the string that must never reach an image loader or the browser.
        @Test(arguments: [
            "file:///Users/me/Documents/tax-return.pdf",
            "javascript:alert(1)",
            "mailto:someone@example.com",
            "ftp://example.com/photo.png",
            "not a url at all"
        ])
        func `Anything that is not a web address has no remote URL`(url: String) {
            #expect(makeAttachment(url: url).remoteURL == nil)
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
