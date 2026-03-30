import Foundation
import Security

/// Reads Adium's XMPP account passwords from the macOS Keychain.
///
/// Adium stores passwords as internet password items (`kSecClassInternetPassword`) with:
/// - Server: `"{ServiceID}.{compactedUID}"` (e.g., `"Jabber.alice@example.com"`)
/// - Account: `"{compactedUID}"` (lowercase, no spaces)
/// - Protocol: `'AdIM'` (FourCharCode `0x4164494d`)
///
/// GTalk accounts use OAuth2 and store refresh tokens as generic passwords instead.
/// The reader returns nil for these — correct graceful degradation.
public enum AdiumKeychainReader {
    /// Attempts to read the password for an Adium account from the macOS Keychain.
    ///
    /// Returns nil if the entry is not found or the user denied access.
    public static func password(for account: AdiumAccount) -> String? {
        // Adium's custom protocol marker 'AdIM' as a FourCharCode (0x4164494d).
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: keychainServerName(for: account),
            kSecAttrAccount as String: keychainAccountName(for: account),
            kSecAttrProtocol as String: 0x4164_494D as CFNumber,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Key Construction

    /// Builds the keychain server name: `"{service}.{compactedUID}"`.
    ///
    /// Uses the service ID as-is (preserving original casing from Adium's plist).
    static func keychainServerName(for account: AdiumAccount) -> String {
        "\(account.service).\(compactedString(account.uid))"
    }

    /// Builds the keychain account name: the compacted UID.
    static func keychainAccountName(for account: AdiumAccount) -> String {
        compactedString(account.uid)
    }

    /// Replicates Adium's `[NSString compactedString]`: lowercase and strip whitespace.
    static func compactedString(_ value: String) -> String {
        value.lowercased().filter { !$0.isWhitespace }
    }
}
