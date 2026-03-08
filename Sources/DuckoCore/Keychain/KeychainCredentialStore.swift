struct KeychainCredentialStore: CredentialStore {
    func savePassword(_ password: String, for jid: String) {
        KeychainHelper.savePassword(password, for: jid)
    }

    func loadPassword(for jid: String) -> String? {
        KeychainHelper.loadPassword(for: jid)
    }

    func deletePassword(for jid: String) {
        KeychainHelper.deletePassword(for: jid)
    }
}
