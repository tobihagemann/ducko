import AppKit

enum CLIInstaller {
    @MainActor
    static func installCLITools() {
        // Use the stable /Applications path so the symlink survives app updates
        // and doesn't break if the user ran the app from a DMG or build directory.
        let cliSource = "/Applications/Ducko.app/Contents/Resources/ducko"
        let cliTarget = "/usr/local/bin/ducko"

        guard FileManager.default.fileExists(atPath: cliSource) else {
            showAlert(
                title: "CLI Not Found",
                message: "Ducko must be installed in /Applications before installing the CLI tools."
            )
            return
        }

        let escapedSource = cliSource.replacingOccurrences(of: "'", with: "'\\''")
        let escapedTarget = cliTarget.replacingOccurrences(of: "'", with: "'\\''")
        let script = "do shell script \"ln -sf '\(escapedSource)' '\(escapedTarget)'\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        Task.detached {
            do {
                try process.run()
                process.waitUntilExit()
                let status = process.terminationStatus

                await MainActor.run {
                    if status == 0 {
                        showAlert(
                            title: "CLI Installed",
                            message: "The \"ducko\" command is now available at \(cliTarget)."
                        )
                    } else {
                        showAlert(
                            title: "Installation Cancelled",
                            message: "CLI installation was cancelled or failed."
                        )
                    }
                }
            } catch {
                let description = error.localizedDescription
                await MainActor.run {
                    showAlert(
                        title: "Installation Failed",
                        message: "Could not run installer: \(description)"
                    )
                }
            }
        }
    }

    @MainActor
    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
