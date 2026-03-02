import Foundation

public enum CredentialStoreFactory {
    public static func makeDefault() -> any CredentialStore {
        if BuildEnvironment.useKeychain {
            return KeychainCredentialStore()
        }
        let dir = BuildEnvironment.appSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return FileCredentialStore(fileURL: dir.appendingPathComponent("credentials.json"))
    }
}
