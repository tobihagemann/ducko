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

private extension ScriptValidationTests {
    @Test(arguments: handlerScriptCases)
    func `shared handler wrappers compile and preserve argv without running the app`(_ fixture: HandlerScriptCase) throws {
        let result = try ScriptRunner.capture(fixture.script, arguments: fixture.arguments, response: fixture.response)
        #expect(result.result.exitCode == 0, "Wrapper failed: \(result.result.stderr)")
        #expect(result.compilerExitCode == 0, "AppleScript failed: \(result.compilerErrors)")
        #expect(result.arguments == fixture.appleScriptArguments)
        #expect(result.invocations == fixture.invocations)
        #expect(result.source.contains("on findByAttr("))
        #expect(result.source.contains("on findByRoleAndName("))
        #expect(!result.source.contains(scriptSpecialArgument))
    }

    @Test(arguments: handlerScriptCases)
    func `wrappers cannot bypass the inert command path`(_ fixture: HandlerScriptCase) throws {
        let source = try String(contentsOf: ScriptRunner.scriptsDirectory.appendingPathComponent(fixture.script), encoding: .utf8)
        let body = source.split(separator: "\n").dropFirst().joined(separator: "\n")
        for prefix in ["/bin/", "/sbin/", "/usr/", "/Applications/", "/System/"] {
            #expect(!body.contains(prefix), "Absolute execution needs a fixture safety review: \(fixture.script)")
        }
        #expect(body.contains("source \"$SCRIPT"))
        #expect(body.contains("$(ducko_as_handlers)"))
    }
}

private struct HandlerScriptCase {
    let script: String
    let arguments: [String]
    let appleScriptArguments: [String]
    var response = "ok"
    var invocations = ["osascript"]
}

private let scriptSpecialArgument = "quote\" and ' newline\n dollar$ backtick` backslash\\ $(not-a-command)"

private let handlerScriptCases: [HandlerScriptCase] = [
    HandlerScriptCase(script: "ducko-add-affiliation.sh", arguments: ["room@example.com", scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument], invocations: ["ducko-room-settings.sh", "ducko-room-settings-tab.sh", "sleep", "osascript"]),
    HandlerScriptCase(script: "ducko-avatar-remove.sh", arguments: [], appleScriptArguments: [], invocations: ["ducko-profile.sh", "osascript"]),
    HandlerScriptCase(script: "ducko-change-password.sh", arguments: [scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument], invocations: ["ducko-preferences.sh", "ducko-preferences-tab.sh", "sleep", "osascript"]),
    HandlerScriptCase(script: "ducko-contact-search.sh", arguments: [scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument], response: "searched"),
    HandlerScriptCase(script: "ducko-destroy-room.sh", arguments: [scriptSpecialArgument], appleScriptArguments: [], invocations: ["ducko-room-settings.sh", "sleep", "osascript"]),
    HandlerScriptCase(script: "ducko-device-trust.sh", arguments: [scriptSpecialArgument, "trust"], appleScriptArguments: ["-", scriptSpecialArgument, "trust"]),
    HandlerScriptCase(script: "ducko-edit-profile.sh", arguments: ["--fullname", scriptSpecialArgument, "--nickname", scriptSpecialArgument, "--email", scriptSpecialArgument, "--save"], appleScriptArguments: ["-", scriptSpecialArgument, scriptSpecialArgument, scriptSpecialArgument, "yes"], invocations: ["ducko-profile.sh", "sleep", "osascript"]),
    HandlerScriptCase(script: "ducko-import.sh", arguments: [], appleScriptArguments: []),
    HandlerScriptCase(script: "ducko-login.sh", arguments: [scriptSpecialArgument, scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument, scriptSpecialArgument]),
    HandlerScriptCase(script: "ducko-register.sh", arguments: [scriptSpecialArgument, scriptSpecialArgument, scriptSpecialArgument, scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument, scriptSpecialArgument, scriptSpecialArgument, scriptSpecialArgument]),
    HandlerScriptCase(script: "ducko-remove-bookmark.sh", arguments: [scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument], invocations: ["ducko-bookmarks.sh", "osascript"]),
    HandlerScriptCase(script: "ducko-room-settings-tab.sh", arguments: ["Members"], appleScriptArguments: ["-", "Members"]),
    HandlerScriptCase(script: "ducko-room-topic.sh", arguments: [scriptSpecialArgument], appleScriptArguments: ["-", scriptSpecialArgument]),
    HandlerScriptCase(script: "ducko-select-mode.sh", arguments: ["Register"], appleScriptArguments: ["-", "Register"]),
    HandlerScriptCase(script: "ducko-connection-info.sh", arguments: [], appleScriptArguments: [], invocations: ["ducko-preferences.sh", "ducko-preferences-tab.sh", "osascript"])
]
