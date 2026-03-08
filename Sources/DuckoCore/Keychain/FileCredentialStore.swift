import Foundation
import os

/// Stores passwords as plaintext JSON on disk. Intended for development only.
final class FileCredentialStore: CredentialStore, @unchecked Sendable {
    // Thread-safe via OSAllocatedUnfairLock — all mutable state accessed only inside withLock.
    private let lock = OSAllocatedUnfairLock(initialState: [String: String]())
    private let fileURL: URL
    private let log = Logger(subsystem: "de.tobiha.ducko", category: "FileCredentialStore")

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let existing = Self.load(from: fileURL) {
            lock.withLock { $0 = existing }
        }
    }

    func savePassword(_ password: String, for jid: String) {
        lock.withLock { $0[jid] = password }
        persist()
        log.notice("Saved password for \(jid, privacy: .public) (file-based, not Keychain)")
    }

    func loadPassword(for jid: String) -> String? {
        lock.withLock { $0[jid] }
    }

    func deletePassword(for jid: String) {
        lock.withLock { _ = $0.removeValue(forKey: jid) }
        persist()
    }

    // MARK: - Private

    private func persist() {
        let snapshot = lock.withLock { $0 }
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            log.warning("Failed to write credentials file: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(from url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }
}
