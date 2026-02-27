import Foundation

enum CredentialHelper {
    /// Returns a password from the environment variable `DUCKO_PASSWORD`,
    /// or prompts interactively via `getpass()` if running in a TTY.
    static func getPassword() -> String? {
        if let envPassword = ProcessInfo.processInfo.environment["DUCKO_PASSWORD"] {
            return envPassword
        }
        guard isatty(STDIN_FILENO) != 0 else { return nil }
        guard let cString = getpass("Password: ") else { return nil }
        return String(cString: cString)
    }
}
