public struct KeychainCredentialStore: CredentialStore {
    public init() {}

    public func savePassword(_ password: String, for jid: String) {
        KeychainHelper.savePassword(password, for: jid)
    }

    public func loadPassword(for jid: String) -> String? {
        KeychainHelper.loadPassword(for: jid)
    }

    public func deletePassword(for jid: String) {
        KeychainHelper.deletePassword(for: jid)
    }
}
