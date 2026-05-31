import ArgumentParser
import Testing
@testable import DuckoCLI

/// The `--port requires --host` guard is shared across `register` and
/// `check-registration` (the `account add` side is covered in `AccountAddTests`).
struct HostPortValidationTests {
    @Test func `register rejects --port without --host`() {
        let error = #expect(throws: (any Error).self) {
            _ = try DuckoCLI.Account.Register.parse([
                "--server", "example.com", "--username", "alice", "--port", "5222"
            ])
        }
        #expect(String(describing: error).contains("--port requires --host"))
    }

    @Test func `register accepts --host with --port`() throws {
        let command = try DuckoCLI.Account.Register.parse([
            "--server", "example.com", "--username", "alice",
            "--host", "127.0.0.1", "--port", "5223"
        ])
        #expect(command.host == "127.0.0.1")
        #expect(command.port == 5223)
    }

    @Test func `check-registration rejects --port without --host`() {
        let error = #expect(throws: (any Error).self) {
            _ = try DuckoCLI.Account.CheckRegistration.parse([
                "--server", "example.com", "--port", "5222"
            ])
        }
        #expect(String(describing: error).contains("--port requires --host"))
    }

    @Test func `check-registration accepts --host with --port`() throws {
        let command = try DuckoCLI.Account.CheckRegistration.parse([
            "--server", "example.com", "--host", "127.0.0.1", "--port", "5223"
        ])
        #expect(command.host == "127.0.0.1")
        #expect(command.port == 5223)
    }
}
