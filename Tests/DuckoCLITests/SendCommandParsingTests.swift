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
}
