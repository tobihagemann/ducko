import Foundation

/// Reads Adium's plist files to discover configured XMPP accounts and their settings.
public enum AdiumAccountDiscovery {
    /// Default Adium user profile path.
    public static let defaultUserURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Adium 2.0/Users/Default")

    /// Discovers XMPP accounts from Adium's Accounts.plist and AccountPrefs.plist.
    ///
    /// Only returns Jabber and GTalk accounts (services that use valid XMPP JIDs).
    public static func discoverAccounts(at userDirectoryURL: URL = defaultUserURL) -> [AdiumAccount] {
        let accountsURL = userDirectoryURL.appendingPathComponent("Accounts.plist")
        guard let data = try? Data(contentsOf: accountsURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let accounts = plist["Accounts"] as? [[String: Any]]
        else {
            return []
        }

        let prefs = loadAccountPrefs(at: userDirectoryURL)

        return accounts.compactMap { dict -> AdiumAccount? in
            guard let objectID = dict["ObjectID"] as? String,
                  let service = dict["Service"] as? String,
                  let uid = dict["UID"] as? String
            else {
                return nil
            }

            let normalizedService = service.lowercased()
            guard normalizedService == "jabber" || normalizedService == "gtalk" else {
                return nil
            }

            let accountPrefs = prefs[objectID] as? [String: Any]
            let connectServer = validHostname(accountPrefs?["Jabber:Connect Server"] as? String)
            let connectPort: Int? = connectServer != nil ? accountPrefs?["Connect Port"] as? Int : nil
            let resource = accountPrefs?["Jabber:Resource"] as? String
            let requireTLS = accountPrefs?["Jabber:Require TLS"] as? Bool ?? true
            let autoConnect = accountPrefs?["AutoConnect"] as? Bool ?? false

            return AdiumAccount(
                id: objectID,
                service: service,
                uid: uid,
                connectServer: connectServer,
                connectPort: connectPort,
                resource: resource,
                requireTLS: requireTLS,
                autoConnect: autoConnect
            )
        }.sorted { $0.uid < $1.uid }
    }

    // MARK: - Private

    private static func loadAccountPrefs(at userDirectoryURL: URL) -> [String: Any] {
        let prefsURL = userDirectoryURL.appendingPathComponent("AccountPrefs.plist")
        guard let data = try? Data(contentsOf: prefsURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return [:]
        }
        return plist
    }

    /// Returns the hostname if it looks like a valid server address, nil otherwise.
    ///
    /// Adium's "Connect Host" field sometimes contains port numbers (e.g. "5222")
    /// instead of hostnames. This validates that the string contains at least one letter
    /// or is a dotted IP address.
    private static func validHostname(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        // Reject if it looks like a bare port number (all digits)
        if value.allSatisfy(\.isNumber) { return nil }
        return value
    }
}
