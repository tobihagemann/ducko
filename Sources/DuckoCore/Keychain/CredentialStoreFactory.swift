import Foundation

enum CredentialStoreFactory {
    static func makeDefault() -> any CredentialStore {
        if BuildEnvironment.useKeychain {
            return KeychainCredentialStore()
        }
        let dir = BuildEnvironment.appSupportDirectory
        // The plaintext credentials file lives directly in this directory, so
        // keep it owner-only. `createDirectory(attributes:)` is a no-op when the
        // directory already exists, so re-apply 0700 explicitly afterward.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return FileCredentialStore(fileURL: dir.appendingPathComponent("credentials.json"))
    }
}
