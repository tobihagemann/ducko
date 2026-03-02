public protocol CredentialStore: Sendable {
    func savePassword(_ password: String, for jid: String)
    func loadPassword(for jid: String) -> String?
    func deletePassword(for jid: String)
}
