import ArgumentParser
import Testing
@testable import DuckoCLI

struct AccountUnregisterTests {
    @Test func `parse unregister command`() throws {
        let command = try DuckoCLI.Account.Unregister.parse(["alice@example.com"])
        #expect(command.jid == "alice@example.com")
    }

    @Test func `parse unregister command with domain`() throws {
        let command = try DuckoCLI.Account.Unregister.parse(["test@xmpp.example.org"])
        #expect(command.jid == "test@xmpp.example.org")
    }

    @Test func `parse unregister command with include history flag`() throws {
        let command = try DuckoCLI.Account.Unregister.parse(["alice@example.com", "--include-history"])
        #expect(command.jid == "alice@example.com")
        #expect(command.includeHistory)
    }

    @Test func `parse unregister command defaults include history to false`() throws {
        let command = try DuckoCLI.Account.Unregister.parse(["alice@example.com"])
        #expect(!command.includeHistory)
    }
}
