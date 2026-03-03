import ArgumentParser
import Testing
@testable import DuckoCLI

struct SendCommandParsingTests {
    @Test func parseWithFileOnly() throws {
        let command = try DuckoCLI.Send.parse(["--file", "/tmp/photo.jpg", "alice@example.com"])
        #expect(command.file == "/tmp/photo.jpg")
        #expect(command.jid == "alice@example.com")
        #expect(command.body == nil)
    }

    @Test func parseWithFileAndBody() throws {
        let command = try DuckoCLI.Send.parse(["--file", "/tmp/photo.jpg", "alice@example.com", "Check this out"])
        #expect(command.file == "/tmp/photo.jpg")
        #expect(command.jid == "alice@example.com")
        #expect(command.body == "Check this out")
    }

    @Test func parseWithBodyOnly() throws {
        let command = try DuckoCLI.Send.parse(["alice@example.com", "Hello"])
        #expect(command.file == nil)
        #expect(command.jid == "alice@example.com")
        #expect(command.body == "Hello")
    }

    @Test func parseWithNoBodyNoFileFailsValidation() {
        #expect(performing: {
            _ = try DuckoCLI.Send.parse(["alice@example.com"])
        }, throws: { error in
            String(describing: error).contains("Provide a message body or --file <path>")
        })
    }

    // MARK: - --method flag

    @Test func parseWithMethodJingle() throws {
        let command = try DuckoCLI.Send.parse(["--file", "test.txt", "--method", "jingle", "alice@example.com"])
        #expect(command.method == "jingle")
        #expect(command.file == "test.txt")
    }

    @Test func parseWithMethodHttp() throws {
        let command = try DuckoCLI.Send.parse(["--file", "test.txt", "--method", "http", "alice@example.com"])
        #expect(command.method == "http")
    }

    @Test func parseWithMethodAuto() throws {
        let command = try DuckoCLI.Send.parse(["--file", "test.txt", "--method", "auto", "alice@example.com"])
        #expect(command.method == "auto")
    }

    @Test func parseWithoutMethodDefaultsToNil() throws {
        let command = try DuckoCLI.Send.parse(["--file", "test.txt", "alice@example.com"])
        #expect(command.method == nil)
    }
}

// MARK: - TransferMethodParsingTests

struct TransferMethodParsingTests {
    @Test func parseAutoMethod() throws {
        let method = try parseTransferMethod("auto")
        #expect(method == .auto)
    }

    @Test func parseHttpMethod() throws {
        let method = try parseTransferMethod("http")
        #expect(method == .httpUpload)
    }

    @Test func parseJingleMethod() throws {
        let method = try parseTransferMethod("jingle")
        #expect(method == .jingle)
    }

    @Test func parseNilDefaultsToAuto() throws {
        let method = try parseTransferMethod(nil)
        #expect(method == .auto)
    }

    @Test func parseCaseInsensitive() throws {
        let method = try parseTransferMethod("JINGLE")
        #expect(method == .jingle)
    }

    @Test func parseInvalidMethodThrows() {
        #expect(throws: CLIError.self) {
            _ = try parseTransferMethod("invalid")
        }
    }
}
