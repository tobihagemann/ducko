import Foundation
import Testing

/// Hermetic, credential-free coverage for the `ducko-ui` automation scripts'
/// argument validation and generated AppleScript. These run on a plain
/// `swift test` with no GUI, accessibility trust, or running app — the
/// UI integration tests are the live backstop for the AX surfaces the scripts
/// drive; this suite tests the scripts themselves.
struct ScriptValidationTests {
    @Test(arguments: [[], ["only-jid"]])
    func `ducko-login rejects missing arguments`(_ arguments: [String]) throws {
        // The bash `${1:?…}` / `${2:?…}` guards fire before any osascript runs.
        let result = try ScriptRunner.run("ducko-login.sh", arguments: arguments)
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("Usage:"))
    }

    @Test(arguments: [[], ["server"], ["server", "user"]])
    func `ducko-register rejects fewer than three arguments`(_ arguments: [String]) throws {
        let result = try ScriptRunner.run("ducko-register.sh", arguments: arguments)
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("Usage:"))
    }

    @Test func `ducko-import parses as valid bash`() throws {
        // `ducko-import.sh` probes for a running app, so it has no hermetic
        // argument-validation surface like login/register. A `bash -n` parse is
        // its deterministic syntax backstop — the live `UIScriptTests` only
        // asserts a nonzero exit, which a syntax error would also produce.
        let script = ScriptRunner.scriptsDirectory.appendingPathComponent("ducko-import.sh").path
        let result = try ScriptRunner.bash(["-n", script])
        #expect(result.exitCode == 0, "bash -n failed: \(result.stderr)")
    }

    @Test func `ducko_as_handlers compiles as standalone AppleScript`() throws {
        let helpers = ScriptRunner.scriptsDirectory.appendingPathComponent("ducko-helpers.sh").path
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).scpt")
        defer { try? FileManager.default.removeItem(at: output) }

        // Positional `$1`/`$2` carry the paths so a spaced checkout path needs
        // no quoting. Handler-only AppleScript is valid and compiles standalone,
        // so a clean `osacompile` exit proves the emitted handlers parse.
        let result = try ScriptRunner.bash([
            "-c",
            "source \"$1\"; ducko_as_handlers | osacompile -o \"$2\" -",
            "bash", helpers, output.path
        ])
        #expect(result.exitCode == 0, "osacompile failed: \(result.stderr)")
    }
}
