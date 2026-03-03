import Foundation
import Testing
@testable import DuckoCLI

// MARK: - PlainFormatter File Transfer Tests

struct PlainFileTransferFormatterTests {
    let formatter = PlainFormatter()

    // MARK: - formatTransferProgress

    @Test func `format transfer progress at zero`() {
        let output = formatter.formatTransferProgress(fileName: "photo.jpg", fileSize: 1_048_576, progress: 0)
        #expect(output.contains("photo.jpg"))
        #expect(output.contains("0%"))
        #expect(output.contains("1 MB"))
    }

    @Test func `format transfer progress at half`() {
        let output = formatter.formatTransferProgress(fileName: "doc.pdf", fileSize: 2_097_152, progress: 0.5)
        #expect(output.contains("doc.pdf"))
        #expect(output.contains("50%"))
    }

    @Test func `format transfer progress at complete`() {
        let output = formatter.formatTransferProgress(fileName: "video.mp4", fileSize: 10_485_760, progress: 1.0)
        #expect(output.contains("video.mp4"))
        #expect(output.contains("100%"))
    }

    // MARK: - formatFileMessage

    @Test func `format file message with size`() {
        let output = formatter.formatFileMessage(fileName: "photo.jpg", url: "https://upload.example.com/photo.jpg", fileSize: 1_048_576)
        #expect(output.contains("photo.jpg"))
        #expect(output.contains("https://upload.example.com/photo.jpg"))
        #expect(output.contains("1 MB"))
    }

    @Test func `format file message without size`() {
        let output = formatter.formatFileMessage(fileName: "doc.pdf", url: "https://upload.example.com/doc.pdf", fileSize: nil)
        #expect(output.contains("doc.pdf"))
        #expect(output.contains("https://upload.example.com/doc.pdf"))
    }

    // MARK: - Jingle Formatter Methods

    @Test func `format file offer`() {
        let output = formatter.formatFileOffer(fileName: "report.pdf", fileSize: 5_242_880, from: "bob@example.com", sid: "sid-123")
        #expect(output.contains("report.pdf"))
        #expect(output.contains("MB"))
        #expect(output.contains("bob@example.com"))
        #expect(output.contains("sid-123"))
        #expect(output.contains("/accept"))
        #expect(output.contains("/decline"))
    }

    @Test func `format jingle transfer progress`() {
        let output = formatter.formatJingleTransferProgress(fileName: "data.zip", fileSize: 10_485_760, progress: 0.75, state: "transferring")
        #expect(output.contains("data.zip"))
        #expect(output.contains("75%"))
        #expect(output.contains("transferring"))
    }

    @Test func `format jingle transfer completed`() {
        let output = formatter.formatJingleTransferCompleted(sid: "sid-456")
        #expect(output.contains("sid-456"))
    }

    @Test func `format jingle transfer failed`() {
        let output = formatter.formatJingleTransferFailed(sid: "sid-789", reason: "connection lost")
        #expect(output.contains("sid-789"))
        #expect(output.contains("connection lost"))
    }
}

// MARK: - ANSIFormatter File Transfer Tests

struct ANSIFileTransferFormatterTests {
    let formatter = ANSIFormatter()

    @Test func `format transfer progress contains carriage return`() {
        let output = formatter.formatTransferProgress(fileName: "photo.jpg", fileSize: 1_048_576, progress: 0.5)
        #expect(output.hasPrefix("\r"))
    }

    @Test func `format transfer progress contains ANSI codes`() {
        let output = formatter.formatTransferProgress(fileName: "photo.jpg", fileSize: 1_048_576, progress: 0.5)
        #expect(output.contains("\u{001B}[36m")) // cyan
        #expect(output.contains("\u{001B}[32m")) // green
        #expect(output.contains("50%"))
    }

    @Test func `format transfer progress contains progress bar`() {
        let output = formatter.formatTransferProgress(fileName: "photo.jpg", fileSize: 1_048_576, progress: 0.5)
        #expect(output.contains("\u{2588}")) // filled block
        #expect(output.contains("\u{2591}")) // empty block
    }

    @Test func `format file message contains bold and cyan`() {
        let output = formatter.formatFileMessage(fileName: "photo.jpg", url: "https://upload.example.com/photo.jpg", fileSize: 1_048_576)
        #expect(output.contains("\u{001B}[1m")) // bold
        #expect(output.contains("\u{001B}[36m")) // cyan
        #expect(output.contains("photo.jpg"))
        #expect(output.contains("https://upload.example.com/photo.jpg"))
    }

    // MARK: - Jingle Formatter Methods

    @Test func `format file offer contains yellow`() {
        let output = formatter.formatFileOffer(fileName: "report.pdf", fileSize: 5_242_880, from: "bob@example.com", sid: "sid-123")
        #expect(output.contains("\u{001B}[33m")) // yellow
        #expect(output.contains("report.pdf"))
        #expect(output.contains("bob@example.com"))
        #expect(output.contains("sid-123"))
    }

    @Test func `format jingle transfer progress contains progress bar`() {
        let output = formatter.formatJingleTransferProgress(fileName: "data.zip", fileSize: 10_485_760, progress: 0.5, state: "transferring")
        #expect(output.hasPrefix("\r"))
        #expect(output.contains("\u{2588}")) // filled block
        #expect(output.contains("transferring"))
        #expect(output.contains("50%"))
    }

    @Test func `format jingle transfer completed contains green`() {
        let output = formatter.formatJingleTransferCompleted(sid: "sid-456")
        #expect(output.contains("\u{001B}[32m")) // green
        #expect(output.contains("sid-456"))
    }

    @Test func `format jingle transfer failed contains red`() {
        let output = formatter.formatJingleTransferFailed(sid: "sid-789", reason: "timeout")
        #expect(output.contains("\u{001B}[31m")) // red
        #expect(output.contains("sid-789"))
        #expect(output.contains("timeout"))
    }
}

// MARK: - JSONFormatter File Transfer Tests

struct JSONFileTransferFormatterTests {
    let formatter = JSONFormatter()

    @Test func `format transfer progress is valid JSON`() throws {
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

    @Test func `format file message is valid JSON`() throws {
        let output = formatter.formatFileMessage(fileName: "photo.jpg", url: "https://upload.example.com/photo.jpg", fileSize: 1_048_576)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "file")
        #expect(json["fileName"] == "photo.jpg")
        #expect(json["url"] == "https://upload.example.com/photo.jpg")
        #expect(json["fileSize"] != nil)
        #expect(json["fileSizeBytes"] == "1048576")
    }

    @Test func `format file message without size omits file size`() throws {
        let output = formatter.formatFileMessage(fileName: "doc.pdf", url: "https://example.com/doc.pdf", fileSize: nil)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "file")
        #expect(json["fileSize"] == nil)
        #expect(json["fileSizeBytes"] == nil)
    }

    // MARK: - Jingle Formatter Methods

    @Test func `format file offer is valid JSON`() throws {
        let output = formatter.formatFileOffer(fileName: "report.pdf", fileSize: 5_242_880, from: "bob@example.com", sid: "sid-123")
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "file_offer")
        #expect(json["fileName"] == "report.pdf")
        #expect(json["from"] == "bob@example.com")
        #expect(json["sid"] == "sid-123")
        #expect(json["fileSizeBytes"] == "5242880")
    }

    @Test func `format jingle transfer progress is valid JSON`() throws {
        let output = formatter.formatJingleTransferProgress(fileName: "data.zip", fileSize: 10_485_760, progress: 0.6, state: "transferring")
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "jingle_transfer_progress")
        #expect(json["fileName"] == "data.zip")
        #expect(json["progress"] == "60")
        #expect(json["state"] == "transferring")
    }

    @Test func `format jingle transfer completed is valid JSON`() throws {
        let output = formatter.formatJingleTransferCompleted(sid: "sid-456")
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "jingle_transfer_completed")
        #expect(json["sid"] == "sid-456")
    }

    @Test func `format jingle transfer failed is valid JSON`() throws {
        let output = formatter.formatJingleTransferFailed(sid: "sid-789", reason: "connection lost")
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "jingle_transfer_failed")
        #expect(json["sid"] == "sid-789")
        #expect(json["reason"] == "connection lost")
    }
}
