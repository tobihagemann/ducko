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

    @Test func `parse add command defaults host port and noConnect`() throws {
        let command = try DuckoCLI.Account.Add.parse(["alice@example.com"])
        #expect(command.host == nil)
        #expect(command.port == nil)
        #expect(command.noConnect == false)
    }

    @Test func `parse add command with host and port`() throws {
        let command = try DuckoCLI.Account.Add.parse([
            "alice@example.com", "--host", "127.0.0.1", "--port", "5223"
        ])
        #expect(command.host == "127.0.0.1")
        #expect(command.port == 5223)
    }

    @Test func `parse add command with no-connect flag`() throws {
        let command = try DuckoCLI.Account.Add.parse([
            "alice@example.com", "--host", "127.0.0.1", "--no-connect"
        ])
        #expect(command.noConnect == true)
    }

    @Test func `validate rejects --port without --host`() {
        let error = #expect(throws: (any Error).self) {
            _ = try DuckoCLI.Account.Add.parse(["alice@example.com", "--port", "5222"])
        }
        #expect(String(describing: error).contains("--port requires --host"))
    }
}
