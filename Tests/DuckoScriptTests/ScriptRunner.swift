import Foundation

/// Captured result of a `Skills/ducko-ui/scripts/*.sh` invocation. The scripts
/// report failures (usage text, "not running") on stderr.
struct ScriptResult {
    let exitCode: Int32
    let stdout: String
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
    static func bash(_ arguments: [String], environment: [String: String]? = nil) throws -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        // Both streams stay far below the pipe buffer, so a sequential drain
        // cannot deadlock the child.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ScriptResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }
}

struct CapturedAppleScript {
    let result: ScriptResult
    let source: String
    let arguments: [String]
    let compilerExitCode: Int32
    let compilerErrors: String
    let invocations: [String]
}

extension ScriptRunner {
    /// Only the selected wrapper and real helpers run. Sibling scripts and app commands
    /// are inert, and osascript captures and compiles its input without executing it.
    static func capture(_ script: String, arguments: [String], response: String = "ok") throws -> CapturedAppleScript {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ducko script fixture \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try installCaptureFixture(in: directory, script: script)
        let captureDirectory = directory.appendingPathComponent("capture")
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let environment = [
            "PATH": directory.appendingPathComponent("bin").path,
            "CAPTURE_DIR": captureDirectory.path,
            "CAPTURE_RESPONSE": response
        ]
        let result = try bash([directory.appendingPathComponent(script).path] + arguments, environment: environment)
        func read(_ name: String) -> String {
            (try? String(contentsOf: captureDirectory.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        return CapturedAppleScript(
            result: result,
            source: read("source.applescript"),
            arguments: read("argv").split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init),
            compilerExitCode: Int32(read("compile-status").trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1,
            compilerErrors: read("compile-errors"),
            invocations: read("invocations").split(separator: "\n").map(String.init)
        )
    }

    private static func installCaptureFixture(in directory: URL, script: String) throws {
        let manager = FileManager.default
        let bin = directory.appendingPathComponent("bin")
        try manager.createDirectory(at: bin, withIntermediateDirectories: true)
        let scripts = try manager.contentsOfDirectory(at: scriptsDirectory, includingPropertiesForKeys: nil)
        for source in scripts where source.pathExtension == "sh" {
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            if source.lastPathComponent == script || source.lastPathComponent == "ducko-helpers.sh" {
                try manager.copyItem(at: source, to: destination)
            } else {
                try writeExecutable(captureNoOp, to: destination)
            }
        }
        for command in ["sleep", "pgrep", "open", "pkill", "killall"] {
            try writeExecutable(captureNoOp, to: bin.appendingPathComponent(command))
        }
        for (name, target) in [("cat", "/bin/cat"), ("dirname", "/usr/bin/dirname")] {
            try manager.createSymbolicLink(atPath: bin.appendingPathComponent(name).path, withDestinationPath: target)
        }
        try writeExecutable(captureOSAScript, to: bin.appendingPathComponent("osascript"))
    }

    private static func writeExecutable(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private let captureNoOp = #"""
#!/bin/bash
printf '%s\n' "${0##*/}" >> "$CAPTURE_DIR/invocations"
exit 0
"""#

private let captureOSAScript = #"""
#!/bin/bash
printf '%s\n' osascript >> "$CAPTURE_DIR/invocations"
if [[ $# -gt 0 ]]; then printf '%s\0' "$@" > "$CAPTURE_DIR/argv"; fi
/bin/cat > "$CAPTURE_DIR/source.applescript"
/usr/bin/osacompile -o "$CAPTURE_DIR/compiled.scpt" "$CAPTURE_DIR/source.applescript" > /dev/null 2> "$CAPTURE_DIR/compile-errors"
status=$?
printf '%s\n' "$status" > "$CAPTURE_DIR/compile-status"
printf '%s\n' "$CAPTURE_RESPONSE"
exit "$status"
"""#
