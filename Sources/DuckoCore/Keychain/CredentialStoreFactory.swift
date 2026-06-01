import Foundation

enum CredentialStoreFactory {
    static func makeDefault() -> any CredentialStore {
        if BuildEnvironment.useKeychain {
            return KeychainCredentialStore()
        }
        let dir = BuildEnvironment.appSupportDirectory
        // The plaintext credentials file lives directly in this directory, so keep it owner-only.
        try? FileManager.default.createOwnerOnlyDirectory(at: dir)
        return FileCredentialStore(fileURL: dir.appendingPathComponent("credentials.json"))
    }
}
