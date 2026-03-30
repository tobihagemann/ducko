import Foundation
import Security
import Testing
@testable import DuckoCore

enum AdiumKeychainReaderTests {
    // MARK: - Helpers

    private static func makeAccount(service: String = "Jabber", uid: String) -> AdiumAccount {
        AdiumAccount(
            id: "test-\(uid)",
            service: service,
            uid: uid,
            connectServer: nil,
            connectPort: nil,
            resource: nil,
            requireTLS: true,
            autoConnect: false
        )
    }

    // MARK: - CompactedString

    struct CompactedString {
        @Test
        func `Lowercases string`() {
            #expect(AdiumKeychainReader.compactedString("Alice@Example.COM") == "alice@example.com")
        }

        @Test
        func `Strips whitespace`() {
            #expect(AdiumKeychainReader.compactedString("alice @example.com") == "alice@example.com")
        }

        @Test
        func `Lowercases and strips whitespace`() {
            #expect(AdiumKeychainReader.compactedString("Alice @Example .COM") == "alice@example.com")
        }

        @Test
        func `Returns empty for empty string`() {
            #expect(AdiumKeychainReader.compactedString("") == "")
        }

        @Test
        func `Leaves already compacted string unchanged`() {
            #expect(AdiumKeychainReader.compactedString("alice@example.com") == "alice@example.com")
        }
    }

    // MARK: - KeyConstruction

    struct KeyConstruction {
        @Test
        func `Jabber account key construction`() {
            let account = makeAccount(uid: "alice@example.com")
            #expect(AdiumKeychainReader.keychainServerName(for: account) == "Jabber.alice@example.com")
            #expect(AdiumKeychainReader.keychainAccountName(for: account) == "alice@example.com")
        }

        @Test
        func `GTalk account key construction`() {
            let account = makeAccount(service: "GTalk", uid: "bob@gmail.com")
            #expect(AdiumKeychainReader.keychainServerName(for: account) == "GTalk.bob@gmail.com")
            #expect(AdiumKeychainReader.keychainAccountName(for: account) == "bob@gmail.com")
        }

        @Test
        func `UID with mixed case is lowercased`() {
            let account = makeAccount(uid: "Alice@Example.COM")
            #expect(AdiumKeychainReader.keychainServerName(for: account) == "Jabber.alice@example.com")
            #expect(AdiumKeychainReader.keychainAccountName(for: account) == "alice@example.com")
        }

        @Test
        func `UID with spaces is compacted`() {
            let account = makeAccount(uid: "alice @example.com")
            #expect(AdiumKeychainReader.keychainServerName(for: account) == "Jabber.alice@example.com")
            #expect(AdiumKeychainReader.keychainAccountName(for: account) == "alice@example.com")
        }

        @Test
        func `Service casing is preserved`() {
            let account = makeAccount(service: "GTalk", uid: "user@gmail.com")
            #expect(AdiumKeychainReader.keychainServerName(for: account).hasPrefix("GTalk."))
        }
    }

    // MARK: - KeychainIntegration

    struct KeychainIntegration {
        private static func addTestItem(server: String, account: String, password: String) -> OSStatus {
            let query: [String: Any] = [
                kSecClass as String: kSecClassInternetPassword,
                kSecAttrServer as String: server,
                kSecAttrAccount as String: account,
                kSecAttrProtocol as String: 0x4164_494D as CFNumber,
                kSecValueData as String: Data(password.utf8)
            ]
            return SecItemAdd(query as CFDictionary, nil)
        }

        private static func deleteTestItem(server: String, account: String) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassInternetPassword,
                kSecAttrServer as String: server,
                kSecAttrAccount as String: account,
                kSecAttrProtocol as String: 0x4164_494D as CFNumber
            ]
            SecItemDelete(query as CFDictionary)
        }

        @Test
        func `Reads password from keychain round trip`() {
            let account = makeAccount(uid: "test-roundtrip@example.com")
            let server = AdiumKeychainReader.keychainServerName(for: account)
            let acctName = AdiumKeychainReader.keychainAccountName(for: account)

            // Clean up any leftover from a previous run
            Self.deleteTestItem(server: server, account: acctName)

            let status = Self.addTestItem(server: server, account: acctName, password: "s3cret")
            #expect(status == errSecSuccess)
            defer { Self.deleteTestItem(server: server, account: acctName) }

            let password = AdiumKeychainReader.password(for: account)
            #expect(password == "s3cret")
        }

        @Test
        func `Returns nil for non-existent account`() {
            let account = makeAccount(uid: "nonexistent-\(UUID().uuidString)@example.com")
            #expect(AdiumKeychainReader.password(for: account) == nil)
        }
    }
}
