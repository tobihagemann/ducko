import DuckoCore
import os

struct MockCredentialStore: CredentialStore {
    private let storage = OSAllocatedUnfairLock(initialState: [String: String]())

    func savePassword(_ password: String, for jid: String) {
        storage.withLock { $0[jid] = password }
    }

    func loadPassword(for jid: String) -> String? {
        storage.withLock { $0[jid] }
    }

    func deletePassword(for jid: String) {
        storage.withLock { $0[jid] = nil }
    }
}
