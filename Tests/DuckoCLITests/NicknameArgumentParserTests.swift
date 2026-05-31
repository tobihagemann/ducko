import Testing
@testable import DuckoCLI

struct NicknameArgumentParserTests {
    @Test func `unquoted single-token nickname without trailing argument`() throws {
        let parsed = try parseNicknameArgument("bob")
        #expect(parsed.nickname == "bob")
        #expect(parsed.trailingArgument == nil)
    }

    @Test func `unquoted single-token nickname with trailing argument`() throws {
        let parsed = try parseNicknameArgument("bob spam")
        #expect(parsed.nickname == "bob")
        #expect(parsed.trailingArgument == "spam")
    }

    @Test func `unquoted nickname with multi-word trailing argument`() throws {
        let parsed = try parseNicknameArgument("bob being disruptive")
        #expect(parsed.nickname == "bob")
        #expect(parsed.trailingArgument == "being disruptive")
    }

    @Test func `quoted whitespace nickname without trailing argument`() throws {
        let parsed = try parseNicknameArgument("\"Alice Smith\"")
        #expect(parsed.nickname == "Alice Smith")
        #expect(parsed.trailingArgument == nil)
    }

    @Test func `quoted whitespace nickname with trailing argument`() throws {
        let parsed = try parseNicknameArgument("\"Alice Smith\" spam")
        #expect(parsed.nickname == "Alice Smith")
        #expect(parsed.trailingArgument == "spam")
    }

    @Test func `quoted nickname with multi-word trailing argument`() throws {
        let parsed = try parseNicknameArgument("\"Alice Smith\" being disruptive")
        #expect(parsed.nickname == "Alice Smith")
        #expect(parsed.trailingArgument == "being disruptive")
    }

    @Test func `escaped quote inside quoted nickname`() throws {
        let parsed = try parseNicknameArgument("\"Alice \\\"Ace\\\" Smith\" hi")
        #expect(parsed.nickname == "Alice \"Ace\" Smith")
        #expect(parsed.trailingArgument == "hi")
    }

    @Test func `escaped backslash inside quoted nickname`() throws {
        let parsed = try parseNicknameArgument("\"Alice\\\\Smith\"")
        #expect(parsed.nickname == "Alice\\Smith")
        #expect(parsed.trailingArgument == nil)
    }

    @Test func `unsupported escape throws`() {
        #expect(throws: CLIError.self) {
            _ = try parseNicknameArgument("\"Al\\ice\"")
        }
    }

    @Test func `dangling trailing backslash throws`() {
        #expect(throws: CLIError.self) {
            _ = try parseNicknameArgument("\"Alice\\")
        }
    }

    @Test func `empty quotes throws`() {
        #expect(throws: CLIError.self) {
            _ = try parseNicknameArgument("\"\"")
        }
    }

    @Test func `unterminated quote throws`() {
        #expect(throws: CLIError.self) {
            _ = try parseNicknameArgument("\"Alice")
        }
    }

    @Test func `characters immediately after closing quote throws`() {
        #expect(throws: CLIError.self) {
            _ = try parseNicknameArgument("\"Alice\"spam")
        }
        #expect(throws: CLIError.self) {
            _ = try parseNicknameArgument("\"Alice\"hello")
        }
    }

    @Test func `mid-token quote treated as literal unquoted token`() throws {
        let parsed = try parseNicknameArgument("bo\"b spam")
        #expect(parsed.nickname == "bo\"b")
        #expect(parsed.trailingArgument == "spam")
    }

    @Test func `leading and trailing whitespace trimmed`() throws {
        let parsed = try parseNicknameArgument("   bob   spam   ")
        #expect(parsed.nickname == "bob")
        #expect(parsed.trailingArgument == "spam")
    }

    @Test func `trailing-whitespace-only yields nil trailing argument`() throws {
        let parsed = try parseNicknameArgument("bob   ")
        #expect(parsed.nickname == "bob")
        #expect(parsed.trailingArgument == nil)
    }

    @Test func `empty input throws`() {
        #expect(throws: CLIError.self) {
            _ = try parseNicknameArgument("")
        }
    }

    @Test func `whitespace-only input throws`() {
        #expect(throws: CLIError.self) {
            _ = try parseNicknameArgument("    ")
        }
    }
}
