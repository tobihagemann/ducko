import Darwin
import DuckoCore

enum CredentialHelper {
    /// Returns a password using a two-tier fallback:
    /// 1. Keychain (if JID provided)
    /// 2. Interactive prompt via `getpass()` (if running in a TTY)
    static func getPassword(for jid: String? = nil) -> String? {
        if let jid, let keychainPassword = KeychainHelper.loadPassword(for: jid) {
            return keychainPassword
        }
        guard isatty(STDIN_FILENO) != 0 else { return nil }
        guard let cString = getpass("Password: ") else { return nil }
        return String(cString: cString)
    }
}
