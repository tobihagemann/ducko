import ArgumentParser
import Testing
@testable import DuckoCLI

struct AccountAddTests {
    @Test func `parse add command`() throws {
        let command = try DuckoCLI.Account.Add.parse(["alice@example.com"])
        #expect(command.jid == "alice@example.com")
    }

    @Test func `parse add command with domain`() throws {
        let command = try DuckoCLI.Account.Add.parse(["test@xmpp.example.org"])
        #expect(command.jid == "test@xmpp.example.org")
    }

    @Test func `parse add command with password option`() throws {
        let command = try DuckoCLI.Account.Add.parse(["alice@example.com", "--password", "secret"])
        #expect(command.jid == "alice@example.com")
        #expect(command.password == "secret")
    }

    @Test func `parse add command defaults password to nil`() throws {
        let command = try DuckoCLI.Account.Add.parse(["alice@example.com"])
        #expect(command.password == nil)
    }
}
