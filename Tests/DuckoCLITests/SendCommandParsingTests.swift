import ArgumentParser
import Testing
@testable import DuckoCLI

struct SendCommandParsingTests {
    @Test func `parse with file only`() throws {
        let command = try DuckoCLI.Send.parse(["--file", "/tmp/photo.jpg", "alice@example.com"])
        #expect(command.file == "/tmp/photo.jpg")
        #expect(command.jid == "alice@example.com")
        #expect(command.body == nil)
    }

    @Test func `parse with file and body`() throws {
        let command = try DuckoCLI.Send.parse(["--file", "/tmp/photo.jpg", "alice@example.com", "Check this out"])
        #expect(command.file == "/tmp/photo.jpg")
        #expect(command.jid == "alice@example.com")
        #expect(command.body == "Check this out")
    }

    @Test func `parse with body only`() throws {
        let command = try DuckoCLI.Send.parse(["alice@example.com", "Hello"])
        #expect(command.file == nil)
        #expect(command.jid == "alice@example.com")
        #expect(command.body == "Hello")
    }

    @Test func `parse with no body no file fails validation`() {
        #expect(performing: {
            _ = try DuckoCLI.Send.parse(["alice@example.com"])
        }, throws: { error in
            String(describing: error).contains("Provide a message body or --file <path>")
        })
    }

    // MARK: - --method flag

    @Test func `parse with method jingle`() throws {
        let command = try DuckoCLI.Send.parse(["--file", "test.txt", "--method", "jingle", "alice@example.com"])
        #expect(command.method == "jingle")
        #expect(command.file == "test.txt")
    }

    @Test func `parse with method http`() throws {
        let command = try DuckoCLI.Send.parse(["--file", "test.txt", "--method", "http", "alice@example.com"])
        #expect(command.method == "http")
    }

    @Test func `parse with method auto`() throws {
        let command = try DuckoCLI.Send.parse(["--file", "test.txt", "--method", "auto", "alice@example.com"])
        #expect(command.method == "auto")
    }

    @Test func `parse without method defaults to nil`() throws {
        let command = try DuckoCLI.Send.parse(["--file", "test.txt", "alice@example.com"])
        #expect(command.method == nil)
    }
}

// MARK: - TransferMethodParsingTests

struct TransferMethodParsingTests {
    @Test func `parse auto method`() throws {
        let method = try parseTransferMethod("auto")
        #expect(method == .auto)
    }

    @Test func `parse http method`() throws {
        let method = try parseTransferMethod("http")
        #expect(method == .httpUpload)
    }

    @Test func `parse jingle method`() throws {
        let method = try parseTransferMethod("jingle")
        #expect(method == .jingle)
    }

    @Test func `parse nil defaults to auto`() throws {
        let method = try parseTransferMethod(nil)
        #expect(method == .auto)
    }

    @Test func `parse case insensitive`() throws {
        let method = try parseTransferMethod("JINGLE")
        #expect(method == .jingle)
    }

    @Test func `parse invalid method throws`() {
        #expect(throws: CLIError.self) {
            _ = try parseTransferMethod("invalid")
        }
    }
}
