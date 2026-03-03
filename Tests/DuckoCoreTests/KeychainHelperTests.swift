import Foundation
import Testing
@testable import DuckoCore

struct KeychainHelperTests {
    private func makeJID() -> String {
        "test-\(UUID().uuidString)@example.com"
    }

    @Test func `save and load`() {
        let jid = makeJID()
        defer { KeychainHelper.deletePassword(for: jid) }

        KeychainHelper.savePassword("secret123", for: jid)
        let loaded = KeychainHelper.loadPassword(for: jid)
        #expect(loaded == "secret123")
    }

    @Test func `update overwrites`() {
        let jid = makeJID()
        defer { KeychainHelper.deletePassword(for: jid) }

        KeychainHelper.savePassword("first", for: jid)
        KeychainHelper.savePassword("second", for: jid)
        let loaded = KeychainHelper.loadPassword(for: jid)
        #expect(loaded == "second")
    }

    @Test func `load non existent returns nil`() {
        let jid = makeJID()
        let loaded = KeychainHelper.loadPassword(for: jid)
        #expect(loaded == nil)
    }

    @Test func `delete removes entry`() {
        let jid = makeJID()

        KeychainHelper.savePassword("toDelete", for: jid)
        KeychainHelper.deletePassword(for: jid)
        let loaded = KeychainHelper.loadPassword(for: jid)
        #expect(loaded == nil)
    }

    @Test func `delete non existent does not throw`() {
        let jid = makeJID()
        KeychainHelper.deletePassword(for: jid)
    }

    @Test func `special characters round trip`() {
        let jid = makeJID()
        defer { KeychainHelper.deletePassword(for: jid) }

        let password = "p@$$w0rd!&*(){}[]|<>?"
        KeychainHelper.savePassword(password, for: jid)
        let loaded = KeychainHelper.loadPassword(for: jid)
        #expect(loaded == password)
    }
}
