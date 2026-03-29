import Foundation
import Testing
@testable import DuckoCore

enum AdiumAccountDiscoveryTests {
    // MARK: - Helpers

    private static func createTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdiumAccountDiscoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeAccountsPlist(_ accounts: [[String: Any]], to dir: URL) throws {
        let plist: [String: Any] = ["Accounts": accounts, "TopAccountID": 99]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent("Accounts.plist"))
    }

    private static func writeAccountPrefsPlist(_ prefs: [String: Any], to dir: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: prefs, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent("AccountPrefs.plist"))
    }

    // MARK: - Tests

    struct Discovery {
        @Test
        func `Discovers Jabber accounts from plists`() throws {
            let dir = try createTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            try writeAccountsPlist([
                ["ObjectID": "1", "Service": "Jabber", "Type": "libpurple-Jabber", "UID": "alice@example.com"],
                ["ObjectID": "2", "Service": "Jabber", "Type": "libpurple-Jabber", "UID": "bob@example.com"]
            ], to: dir)

            try writeAccountPrefsPlist([
                "1": [
                    "Jabber:Resource": "laptop",
                    "Jabber:Require TLS": true,
                    "AutoConnect": true
                ] as [String: Any],
                "2": [
                    "Jabber:Resource": "phone",
                    "AutoConnect": false
                ] as [String: Any]
            ], to: dir)

            let accounts = AdiumAccountDiscovery.discoverAccounts(at: dir)
            #expect(accounts.count == 2)

            let alice = accounts[0]
            #expect(alice.uid == "alice@example.com")
            #expect(alice.service == "Jabber")
            #expect(alice.resource == "laptop")
            #expect(alice.requireTLS == true)
            #expect(alice.autoConnect == true)
            #expect(alice.connectServer == nil)
            #expect(alice.connectPort == nil)

            let bob = accounts[1]
            #expect(bob.uid == "bob@example.com")
            #expect(bob.resource == "phone")
            #expect(bob.autoConnect == false)
        }

        @Test
        func `Discovers GTalk accounts`() throws {
            let dir = try createTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            try writeAccountsPlist([
                ["ObjectID": "1", "Service": "GTalk", "Type": "libpurple-Jabber", "UID": "user@gmail.com"]
            ], to: dir)

            let accounts = AdiumAccountDiscovery.discoverAccounts(at: dir)
            #expect(accounts.count == 1)
            #expect(accounts[0].uid == "user@gmail.com")
            #expect(accounts[0].service == "GTalk")
        }

        @Test
        func `Reads connect server and port`() throws {
            let dir = try createTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            try writeAccountsPlist([
                ["ObjectID": "1", "Service": "Jabber", "Type": "libpurple-Jabber", "UID": "alice@example.com"]
            ], to: dir)

            try writeAccountPrefsPlist([
                "1": [
                    "Jabber:Connect Server": "xmpp.example.com",
                    "Connect Port": 5223
                ] as [String: Any]
            ], to: dir)

            let accounts = AdiumAccountDiscovery.discoverAccounts(at: dir)
            #expect(accounts[0].connectServer == "xmpp.example.com")
            #expect(accounts[0].connectPort == 5223)
        }
    }

    struct Filtering {
        @Test
        func `Filters out non-XMPP accounts`() throws {
            let dir = try createTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            try writeAccountsPlist([
                ["ObjectID": "1", "Service": "ICQ", "Type": "libpurple-oscar-ICQ", "UID": "101494097"],
                ["ObjectID": "2", "Service": "Jabber", "Type": "libpurple-Jabber", "UID": "alice@example.com"],
                ["ObjectID": "3", "Service": "Facebook", "Type": "FBXMPP", "UID": "100001488283664"],
                ["ObjectID": "4", "Service": "AIM", "Type": "libpurple-oscar-AIM", "UID": "musclerumble"]
            ], to: dir)

            let accounts = AdiumAccountDiscovery.discoverAccounts(at: dir)
            #expect(accounts.count == 1)
            #expect(accounts[0].uid == "alice@example.com")
        }
    }

    struct MissingFiles {
        @Test
        func `Returns empty for missing Accounts plist`() throws {
            let dir = try createTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            let accounts = AdiumAccountDiscovery.discoverAccounts(at: dir)
            #expect(accounts.isEmpty)
        }

        @Test
        func `Works without AccountPrefs plist`() throws {
            let dir = try createTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            try writeAccountsPlist([
                ["ObjectID": "1", "Service": "Jabber", "Type": "libpurple-Jabber", "UID": "alice@example.com"]
            ], to: dir)

            let accounts = AdiumAccountDiscovery.discoverAccounts(at: dir)
            #expect(accounts.count == 1)
            #expect(accounts[0].resource == nil)
            #expect(accounts[0].connectServer == nil)
            #expect(accounts[0].requireTLS == true)
            #expect(accounts[0].autoConnect == false)
        }
    }

    struct Validation {
        @Test
        func `Rejects port number as connect server`() throws {
            let dir = try createTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            try writeAccountsPlist([
                ["ObjectID": "1", "Service": "Jabber", "Type": "libpurple-Jabber", "UID": "alice@example.com"]
            ], to: dir)

            try writeAccountPrefsPlist([
                "1": [
                    "Jabber:Connect Server": "5222",
                    "Connect Port": 5222
                ] as [String: Any]
            ], to: dir)

            let accounts = AdiumAccountDiscovery.discoverAccounts(at: dir)
            #expect(accounts[0].connectServer == nil)
            #expect(accounts[0].connectPort == nil)
        }

        @Test
        func `Rejects empty connect server`() throws {
            let dir = try createTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            try writeAccountsPlist([
                ["ObjectID": "1", "Service": "Jabber", "Type": "libpurple-Jabber", "UID": "alice@example.com"]
            ], to: dir)

            try writeAccountPrefsPlist([
                "1": [
                    "Jabber:Connect Server": ""
                ] as [String: Any]
            ], to: dir)

            let accounts = AdiumAccountDiscovery.discoverAccounts(at: dir)
            #expect(accounts[0].connectServer == nil)
        }
    }

    struct Sorting {
        @Test
        func `Accounts are sorted by UID`() throws {
            let dir = try createTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            try writeAccountsPlist([
                ["ObjectID": "1", "Service": "Jabber", "Type": "libpurple-Jabber", "UID": "zara@example.com"],
                ["ObjectID": "2", "Service": "Jabber", "Type": "libpurple-Jabber", "UID": "alice@example.com"],
                ["ObjectID": "3", "Service": "GTalk", "Type": "libpurple-Jabber", "UID": "bob@gmail.com"]
            ], to: dir)

            let accounts = AdiumAccountDiscovery.discoverAccounts(at: dir)
            #expect(accounts.map(\.uid) == ["alice@example.com", "bob@gmail.com", "zara@example.com"])
        }
    }
}
