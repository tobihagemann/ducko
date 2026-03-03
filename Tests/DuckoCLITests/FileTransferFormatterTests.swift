import Foundation
import Testing
@testable import DuckoCLI

// MARK: - PlainFormatter File Transfer Tests

struct PlainFileTransferFormatterTests {
    let formatter = PlainFormatter()

    // MARK: - formatTransferProgress

    @Test func formatTransferProgressAtZero() {
        let output = formatter.formatTransferProgress(fileName: "photo.jpg", fileSize: 1_048_576, progress: 0)
        #expect(output.contains("photo.jpg"))
        #expect(output.contains("0%"))
        #expect(output.contains("1 MB"))
    }

    @Test func formatTransferProgressAtHalf() {
        let output = formatter.formatTransferProgress(fileName: "doc.pdf", fileSize: 2_097_152, progress: 0.5)
        #expect(output.contains("doc.pdf"))
        #expect(output.contains("50%"))
    }

    @Test func formatTransferProgressAtComplete() {
        let output = formatter.formatTransferProgress(fileName: "video.mp4", fileSize: 10_485_760, progress: 1.0)
        #expect(output.contains("video.mp4"))
        #expect(output.contains("100%"))
    }

    // MARK: - formatFileMessage

    @Test func formatFileMessageWithSize() {
        let output = formatter.formatFileMessage(fileName: "photo.jpg", url: "https://upload.example.com/photo.jpg", fileSize: 1_048_576)
        #expect(output.contains("photo.jpg"))
        #expect(output.contains("https://upload.example.com/photo.jpg"))
        #expect(output.contains("1 MB"))
    }

    @Test func formatFileMessageWithoutSize() {
        let output = formatter.formatFileMessage(fileName: "doc.pdf", url: "https://upload.example.com/doc.pdf", fileSize: nil)
        #expect(output.contains("doc.pdf"))
        #expect(output.contains("https://upload.example.com/doc.pdf"))
    }
}

// MARK: - ANSIFormatter File Transfer Tests

struct ANSIFileTransferFormatterTests {
    let formatter = ANSIFormatter()

    @Test func formatTransferProgressContainsCarriageReturn() {
        let output = formatter.formatTransferProgress(fileName: "photo.jpg", fileSize: 1_048_576, progress: 0.5)
        #expect(output.hasPrefix("\r"))
    }

    @Test func formatTransferProgressContainsANSICodes() {
        let output = formatter.formatTransferProgress(fileName: "photo.jpg", fileSize: 1_048_576, progress: 0.5)
        #expect(output.contains("\u{001B}[36m")) // cyan
        #expect(output.contains("\u{001B}[32m")) // green
        #expect(output.contains("50%"))
    }

    @Test func formatTransferProgressContainsProgressBar() {
        let output = formatter.formatTransferProgress(fileName: "photo.jpg", fileSize: 1_048_576, progress: 0.5)
        #expect(output.contains("\u{2588}")) // filled block
        #expect(output.contains("\u{2591}")) // empty block
    }

    @Test func formatFileMessageContainsBoldAndCyan() {
        let output = formatter.formatFileMessage(fileName: "photo.jpg", url: "https://upload.example.com/photo.jpg", fileSize: 1_048_576)
        #expect(output.contains("\u{001B}[1m")) // bold
        #expect(output.contains("\u{001B}[36m")) // cyan
        #expect(output.contains("photo.jpg"))
        #expect(output.contains("https://upload.example.com/photo.jpg"))
    }
}

// MARK: - JSONFormatter File Transfer Tests

struct JSONFileTransferFormatterTests {
    let formatter = JSONFormatter()

    @Test func formatTransferProgressIsValidJSON() throws {
        let output = formatter.formatTransferProgress(fileName: "photo.jpg", fileSize: 1_048_576, progress: 0.45)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "transfer_progress")
        #expect(json["fileName"] == "photo.jpg")
        #expect(json["progress"] == "45")
    }

    @Test func formatTransferProgressAtComplete() throws {
        let output = formatter.formatTransferProgress(fileName: "doc.pdf", fileSize: 2_097_152, progress: 1.0)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["progress"] == "100")
    }

    @Test func formatFileMessageIsValidJSON() throws {
        let output = formatter.formatFileMessage(fileName: "photo.jpg", url: "https://upload.example.com/photo.jpg", fileSize: 1_048_576)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "file")
        #expect(json["fileName"] == "photo.jpg")
        #expect(json["url"] == "https://upload.example.com/photo.jpg")
        #expect(json["fileSize"] != nil)
        #expect(json["fileSizeBytes"] == "1048576")
    }

    @Test func formatFileMessageWithoutSizeOmitsFileSize() throws {
        let output = formatter.formatFileMessage(fileName: "doc.pdf", url: "https://example.com/doc.pdf", fileSize: nil)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "file")
        #expect(json["fileSize"] == nil)
        #expect(json["fileSizeBytes"] == nil)
    }
}
