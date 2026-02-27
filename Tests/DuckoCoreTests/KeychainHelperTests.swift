import Foundation
import Testing
@testable import DuckoCore

struct KeychainHelperTests {
    private func makeJID() -> String {
        "test-\(UUID().uuidString)@example.com"
    }

    @Test func saveAndLoad() {
        let jid = makeJID()
        defer { KeychainHelper.deletePassword(for: jid) }

        KeychainHelper.savePassword("secret123", for: jid)
        let loaded = KeychainHelper.loadPassword(for: jid)
        #expect(loaded == "secret123")
    }

    @Test func updateOverwrites() {
        let jid = makeJID()
        defer { KeychainHelper.deletePassword(for: jid) }

        KeychainHelper.savePassword("first", for: jid)
        KeychainHelper.savePassword("second", for: jid)
        let loaded = KeychainHelper.loadPassword(for: jid)
        #expect(loaded == "second")
    }

    @Test func loadNonExistentReturnsNil() {
        let jid = makeJID()
        let loaded = KeychainHelper.loadPassword(for: jid)
        #expect(loaded == nil)
    }

    @Test func deleteRemovesEntry() {
        let jid = makeJID()

        KeychainHelper.savePassword("toDelete", for: jid)
        KeychainHelper.deletePassword(for: jid)
        let loaded = KeychainHelper.loadPassword(for: jid)
        #expect(loaded == nil)
    }

    @Test func deleteNonExistentDoesNotThrow() {
        let jid = makeJID()
        KeychainHelper.deletePassword(for: jid)
    }

    @Test func specialCharactersRoundTrip() {
        let jid = makeJID()
        defer { KeychainHelper.deletePassword(for: jid) }

        let password = "p@$$w0rd!&*(){}[]|<>?"
        KeychainHelper.savePassword(password, for: jid)
        let loaded = KeychainHelper.loadPassword(for: jid)
        #expect(loaded == password)
    }
}
