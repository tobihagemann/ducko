import ArgumentParser
import Testing
@testable import DuckoCLI

struct AccountDeleteTests {
    @Test func `parse delete command`() throws {
        let command = try DuckoCLI.Account.Delete.parse(["alice@example.com"])
        #expect(command.jid == "alice@example.com")
    }

    @Test func `parse delete command with domain`() throws {
        let command = try DuckoCLI.Account.Delete.parse(["test@xmpp.example.org"])
        #expect(command.jid == "test@xmpp.example.org")
    }
}
