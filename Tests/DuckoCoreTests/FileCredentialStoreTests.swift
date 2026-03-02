import Foundation
import Testing
@testable import DuckoCore

struct FileCredentialStoreTests {
    private func makeTempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-credentials-\(UUID().uuidString).json")
    }

    @Test func saveAndLoad() {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileCredentialStore(fileURL: url)
        store.savePassword("secret123", for: "alice@example.com")
        let loaded = store.loadPassword(for: "alice@example.com")
        #expect(loaded == "secret123")
    }

    @Test func updateOverwrites() {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileCredentialStore(fileURL: url)
        store.savePassword("first", for: "alice@example.com")
        store.savePassword("second", for: "alice@example.com")
        let loaded = store.loadPassword(for: "alice@example.com")
        #expect(loaded == "second")
    }

    @Test func loadNonExistentReturnsNil() {
        let url = makeTempURL()
        let store = FileCredentialStore(fileURL: url)
        #expect(store.loadPassword(for: "nobody@example.com") == nil)
    }

    @Test func deleteRemovesEntry() {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileCredentialStore(fileURL: url)
        store.savePassword("secret", for: "alice@example.com")
        store.deletePassword(for: "alice@example.com")
        #expect(store.loadPassword(for: "alice@example.com") == nil)
    }

    @Test func deleteNonExistentDoesNotThrow() {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileCredentialStore(fileURL: url)
        store.deletePassword(for: "nobody@example.com")
    }

    @Test func persistsAcrossInstances() {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store1 = FileCredentialStore(fileURL: url)
        store1.savePassword("persist-me", for: "bob@example.com")

        let store2 = FileCredentialStore(fileURL: url)
        let loaded = store2.loadPassword(for: "bob@example.com")
        #expect(loaded == "persist-me")
    }

    @Test func specialCharactersRoundTrip() {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileCredentialStore(fileURL: url)
        let password = "p@$$w0rd!&*(){}[]|<>?"
        store.savePassword(password, for: "alice@example.com")
        let loaded = store.loadPassword(for: "alice@example.com")
        #expect(loaded == password)
    }
}
