import Foundation
import Testing
@testable import DuckoCore

struct FileCredentialStoreTests {
    private func makeTempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-credentials-\(UUID().uuidString).json")
    }

    @Test func `save and load`() {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileCredentialStore(fileURL: url)
        store.savePassword("secret123", for: "alice@example.com")
        let loaded = store.loadPassword(for: "alice@example.com")
        #expect(loaded == "secret123")
    }

    @Test func `update overwrites`() {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileCredentialStore(fileURL: url)
        store.savePassword("first", for: "alice@example.com")
        store.savePassword("second", for: "alice@example.com")
        let loaded = store.loadPassword(for: "alice@example.com")
        #expect(loaded == "second")
    }

    @Test func `load non existent returns nil`() {
        let url = makeTempURL()
        let store = FileCredentialStore(fileURL: url)
        #expect(store.loadPassword(for: "nobody@example.com") == nil)
    }

    @Test func `delete removes entry`() {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileCredentialStore(fileURL: url)
        store.savePassword("secret", for: "alice@example.com")
        store.deletePassword(for: "alice@example.com")
        #expect(store.loadPassword(for: "alice@example.com") == nil)
    }

    @Test func `delete non existent does not throw`() {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileCredentialStore(fileURL: url)
        store.deletePassword(for: "nobody@example.com")
    }

    @Test func `persists across instances`() {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store1 = FileCredentialStore(fileURL: url)
        store1.savePassword("persist-me", for: "bob@example.com")

        let store2 = FileCredentialStore(fileURL: url)
        let loaded = store2.loadPassword(for: "bob@example.com")
        #expect(loaded == "persist-me")
    }

    @Test func `special characters round trip`() {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileCredentialStore(fileURL: url)
        let password = "p@$$w0rd!&*(){}[]|<>?"
        store.savePassword(password, for: "alice@example.com")
        let loaded = store.loadPassword(for: "alice@example.com")
        #expect(loaded == password)
    }
}
