import Foundation
import Logging

private let log = Logger(label: "im.ducko.integrationtests.cli")

/// Captured stdout, stderr, and exit code from a one-shot `ducko` invocation.
struct CLIOutput {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

/// Spawns the debug-built `ducko` binary as a child process and exposes a
/// scoped helper that mirrors `TestHarness.withHarness` lifecycle semantics.
///
/// Each `CLIProcess` carries a `DUCKO_PROFILE` so its credentials, transcripts,
/// and SwiftData metadata are isolated under
/// `~/Library/Application Support/Ducko-Dev-<profile>/` and torn down when the
/// helper closure returns.
///
/// State held by the actor is the env dictionary passed to spawned processes
/// plus the LIFO `cleanupActions` queue that REPL sessions register against;
/// public methods are `async` so callers do not need to think about isolation.
actor CLIProcess {
    nonisolated let profile: String
    nonisolated let environment: [String: String]
    private var cleanupActions: [@Sendable () async -> Void] = []

    init(profile: String) {
        self.profile = profile

        // Inherit only the environment variables the CLI needs to find Foundation
        // bundles, locales, and the user's home directory; everything else stays
        // unset so a stray DUCKO_USE_KEYCHAIN=1 in the developer's shell does not
        // route test passwords into the macOS Keychain.
        let parent = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "DUCKO_PROFILE": profile
        ]
        for key in ["HOME", "PATH", "LANG", "LC_ALL"] {
            if let value = parent[key] {
                env[key] = value
            }
        }
        self.environment = env
    }

    /// Path to the debug-built CLI binary. Resolved relative to this file via
    /// `#filePath` so checkout location does not matter; mirrors the walk-up
    /// pattern in `TestCredentials.swift:90-94`.
    static var binaryPath: URL {
        // CLIProcess.swift lives at:
        //   IntegrationTests/Tests/DuckoIntegrationTests/CLI/CLIProcess.swift
        // The debug CLI binary lives at:
        //   .build/debug/DuckoCLI
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CLI
            .deletingLastPathComponent() // DuckoIntegrationTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // IntegrationTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent(".build")
            .appendingPathComponent("debug")
            .appendingPathComponent("DuckoCLI")
    }

    /// Suite-level skip predicate — CLI tests need a debug-built binary on disk.
    static var binaryExists: Bool {
        FileManager.default.isExecutableFile(atPath: binaryPath.path)
    }

    // MARK: - Lifecycle

    /// Runs `body` with a fresh `CLIProcess`, awaiting profile cleanup and any
    /// registered REPL terminations on both success and failure paths. Mirrors
    /// `TestHarness.withHarness` (`TestHarness.swift:33-58`) since Swift `defer`
    /// cannot await.
    static func withProcess<T: Sendable>(
        profile: String? = nil,
        _ body: sending (CLIProcess) async throws -> T
    ) async throws -> T {
        let resolvedProfile = profile ?? "inttest-\(UUID().uuidString.prefix(8))"
        let cli = CLIProcess(profile: resolvedProfile)
        do {
            let result = try await body(cli)
            await cli.tearDown()
            return result
        } catch {
            await cli.tearDown()
            throw error
        }
    }

    /// Appends a cleanup action; actions run in reverse order during teardown.
    func addCleanup(_ action: @escaping @Sendable () async -> Void) {
        cleanupActions.append(action)
    }

    // MARK: - Spawning

    /// Runs `ducko <arguments>` to completion and returns its captured output.
    /// Throws `TestHarnessError.binaryMissing` if the debug binary is absent
    /// and `TestHarnessError.timeout` if the process does not exit in time
    /// even after a SIGTERM/SIGKILL escalation.
    func run(
        _ arguments: [String],
        stdin: String? = nil,
        timeout: Duration = TestTimeout.cliCommand
    ) async throws -> CLIOutput {
        let binary = Self.binaryPath
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw TestHarnessError.binaryMissing(path: binary.path)
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        try process.run()

        if let stdin {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
        }
        try? stdinPipe.fileHandleForWriting.close()

        // Capture pipes on detached tasks so a stuck child doesn't deadlock
        // waitUntilExit by filling the pipe buffer.
        let stdoutTask = Task.detached { (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data() }
        let stderrTask = Task.detached { (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data() }

        let exited = await Self.waitForProcessExit(process, timeout: timeout)
        if !exited {
            await Self.killProcess(process)
            // Drain reader tasks before throwing so they don't outlive this
            // function holding open pipe fds. Once `killProcess` reaps the
            // child, the pipe write ends close and `readToEnd()` returns.
            _ = await stdoutTask.value
            _ = await stderrTask.value
            log.warning("CLI invocation timed out: ducko \(Self.redactArguments(arguments).joined(separator: " "))")
            throw TestHarnessError.timeout
        }

        let stdoutData = await stdoutTask.value
        let stderrData = await stderrTask.value

        return CLIOutput(
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }

    /// Adds an account to this profile via `ducko account add` and throws on
    /// non-zero exit. Mirrors the seeding `REPLSession.start` does internally
    /// so call sites that don't spawn a REPL share the same code path.
    @discardableResult
    func seedAccount(_ credential: TestCredentials.Credential) async throws -> CLIOutput {
        let output = try await run([
            "account", "add", credential.jid, "--password", credential.password
        ])
        guard output.exitCode == 0 else {
            throw TestHarnessError.nonZeroExit(
                code: output.exitCode, stdout: output.stdout, stderr: output.stderr
            )
        }
        return output
    }

    /// Removes the on-disk profile directory under
    /// `~/Library/Application Support/Ducko-Dev-<profile>/`. Idempotent.
    func cleanupProfileDirectory() async {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ducko-Dev-\(profile)", isDirectory: true)
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Profile directory was never created — expected for tests that
            // don't run any CLI invocation.
        } catch {
            log.warning("Failed to remove profile directory \(url.path): \(error.localizedDescription)")
        }
    }

    // MARK: - Process lifecycle helpers

    /// Polls `process.isRunning` until exit or timeout. Returns `true` on
    /// natural exit, `false` on timeout. Cooperative-cancellation friendly,
    /// unlike `Task.detached { process.waitUntilExit() }.value` which holds a
    /// thread until the process completes regardless of cancellation.
    nonisolated static func waitForProcessExit(
        _ process: Process,
        timeout: Duration,
        pollInterval: Duration = .milliseconds(50)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if !process.isRunning { return true }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                // Outer cancellation (e.g. from a containing `runWithTimeout`'s
                // `cancelAll()` once the soft deadline fires) — return current
                // process state immediately so the caller can unwind. Without
                // this, swallowing the cancellation would busy-spin the loop
                // until the original deadline expires.
                return !process.isRunning
            }
        }
        return !process.isRunning
    }

    /// Escalates from SIGTERM to SIGKILL with grace periods between, then
    /// awaits the final exit. Used on timeout paths where the child has
    /// already missed its deadline.
    nonisolated static func killProcess(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        if await waitForProcessExit(process, timeout: .seconds(2)) { return }
        kill(process.processIdentifier, SIGKILL)
        _ = await waitForProcessExit(process, timeout: .seconds(2))
    }

    /// Redacts the value following `--password` so timeout warning logs do not
    /// leak test credentials. CLAUDE.md privacy policy bars passwords in
    /// `warning`-level logs.
    nonisolated static func redactArguments(_ arguments: [String]) -> [String] {
        var redacted: [String] = []
        var redactNext = false
        for arg in arguments {
            if redactNext {
                redacted.append("<redacted>")
                redactNext = false
            } else {
                redacted.append(arg)
                if arg == "--password" { redactNext = true }
            }
        }
        return redacted
    }

    // MARK: - Teardown

    private func tearDown() async {
        // Mirror `TestHarness.runWithTimeout` (`TestHarness.swift:533-549`):
        // bound each cleanup so a stuck `REPLSession.terminate` (e.g. reader
        // wedged on a POSIX read) cannot hang the suite.
        for action in cleanupActions.reversed() {
            await Self.runWithTimeout(action, timeout: .seconds(5))
        }
        cleanupActions.removeAll()
        await cleanupProfileDirectory()
    }

    private nonisolated static func runWithTimeout(
        _ action: @escaping @Sendable () async -> Void,
        timeout: Duration
    ) async {
        let timedOut: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await action()
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return true
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if timedOut {
            log.warning("CLI cleanup action timed out after \(timeout)")
        }
    }
}
