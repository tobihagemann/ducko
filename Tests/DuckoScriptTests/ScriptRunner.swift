import Foundation

/// Captured result of a `Skills/ducko-ui/scripts/*.sh` invocation. The scripts
/// report failures (usage text, "not running") on stderr, so stdout is drained
/// to avoid a full-pipe deadlock but not retained.
struct ScriptResult {
    let exitCode: Int32
    let stderr: String
}

/// Spawns the ducko-ui automation scripts under `/bin/bash` for hermetic,
/// credential-free assertions on their argument validation and generated
/// AppleScript. The scripts directory is resolved relative to this file via
/// `#filePath` — mirroring `CLIProcess`'s walk-up — so checkout location does
/// not matter.
enum ScriptRunner {
    /// `Tests/DuckoScriptTests/ScriptRunner.swift` → `<repo>/Skills/ducko-ui/scripts`.
    static var scriptsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DuckoScriptTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Skills")
            .appendingPathComponent("ducko-ui")
            .appendingPathComponent("scripts")
    }

    /// Runs `script` (a bare filename under `scriptsDirectory`) with `arguments`
    /// and returns its exit code and captured streams.
    static func run(_ script: String, arguments: [String] = []) throws -> ScriptResult {
        try bash([scriptsDirectory.appendingPathComponent(script).path] + arguments)
    }

    /// Runs `/bin/bash` with the given argument vector. Callers pass paths as
    /// positional parameters (`bash -c '… "$1" …' bash <path>`) rather than
    /// interpolating them into the command string, so a checkout path with
    /// spaces needs no shell quoting.
    static func bash(_ arguments: [String]) throws -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        // The scripts emit only short usage lines or osacompile diagnostics, so
        // a sequential drain cannot fill the pipe buffer and deadlock the child.
        _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ScriptResult(
            exitCode: process.terminationStatus,
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }
}
