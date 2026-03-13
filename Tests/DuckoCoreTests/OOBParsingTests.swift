import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

struct OOBParsingTests {
    @Test
    func `OOB namespace constant is correct`() {
        #expect(XMPPNamespaces.oob == "jabber:x:oob")
    }

    @Test
    func `Attachment with URL and fileName`() {
        let attachment = DuckoCore.Attachment(id: UUID(), url: "https://example.com/file.jpg", fileName: "photo.jpg")
        #expect(attachment.url == "https://example.com/file.jpg")
        #expect(attachment.fileName == "photo.jpg")
        #expect(attachment.displayFileName == "photo.jpg")
    }

    @Test
    func `Attachment displayFileName falls back to URL path`() {
        let attachment = DuckoCore.Attachment(id: UUID(), url: "https://example.com/path/document.pdf")
        #expect(attachment.displayFileName == "document.pdf")
    }

    @Test
    func `Attachment isImage checks mimeType`() {
        let image = DuckoCore.Attachment(id: UUID(), url: "https://example.com/a.jpg", mimeType: "image/jpeg")
        let nonImage = DuckoCore.Attachment(id: UUID(), url: "https://example.com/b.pdf", mimeType: "application/pdf")
        let noMime = DuckoCore.Attachment(id: UUID(), url: "https://example.com/c.txt")
        #expect(image.isImage)
        #expect(!nonImage.isImage)
        #expect(!noMime.isImage)
    }
}
