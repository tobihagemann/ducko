import AppKit
import Foundation
import Testing

extension DuckoIntegrationTests.UILayer {
    /// Lives under `UILayer` so it inherits the root suite's `.serialized` trait
    /// — `ducko-import.sh` checks `exists process "DuckoApp"`, so it must not run
    /// while an app-launching UI test has its own bundle live. Nesting here also
    /// inherits `.enabled(if: TestCredentials.isAvailable)`, so this case skips
    /// without credentials even though the script failure it covers needs none;
    /// the always-on, credential-free script coverage is `DuckoScriptTests`'s job
    /// in the main package.
    struct UIScriptTests {
        @Test(.enabled(
            if: AppAccessor.appBundleExists && AppAccessor.isAccessibilityTrusted && AppAccessor.noDuckoAppRunning,
            "Ducko.app missing, AX trust not granted, or a DuckoApp instance is running"
        ))
        @MainActor func `import script reports when no app is running`() throws {
            let result = try Self.runImportScript()
            #expect(result.exitCode != 0)

            // The `DuckoApp is not running` message comes from the osascript
            // `System Events` branch, which needs Automation
            // (`kTCCServiceAppleEvents`) permission — distinct from the
            // Accessibility trust the gate checks. When Automation is ungranted,
            // osascript fails with a permission error first and the substring
            // never appears, though the script still exits nonzero. Treat the
            // substring as a tolerated soft check so a missing Automation grant
            // doesn't flake the suite; the nonzero exit is the hard assertion.
            withKnownIssue(
                "DuckoApp-not-running message requires Automation (kTCCServiceAppleEvents) permission",
                isIntermittent: true
            ) {
                #expect(result.stderr.contains("DuckoApp is not running"))
            }
        }

        /// Spawns `Skills/ducko-ui/scripts/ducko-import.sh` under `/bin/bash` and
        /// returns its exit code and stderr. A local `Process` spawn — the
        /// `ScriptRunner` lives in the main package's `DuckoScriptTests`
        /// target, which is not a product and so cannot be imported here. The
        /// `#filePath`→repo-root walk-up mirrors `CLIProcess`.
        private static func runImportScript() throws -> (exitCode: Int32, stderr: String) {
            let script = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // UI
                .deletingLastPathComponent() // DuckoIntegrationTests
                .deletingLastPathComponent() // Tests
                .deletingLastPathComponent() // IntegrationTests
                .deletingLastPathComponent() // repo root
                .appendingPathComponent("Skills")
                .appendingPathComponent("ducko-ui")
                .appendingPathComponent("scripts")
                .appendingPathComponent("ducko-import.sh")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path]
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = FileHandle.nullDevice

            try process.run()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: stderrData, as: UTF8.self))
        }
    }
}
