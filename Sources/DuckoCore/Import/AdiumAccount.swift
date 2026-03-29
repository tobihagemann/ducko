import Foundation

/// A discovered XMPP account from Adium's configuration files.
public struct AdiumAccount: Sendable, Identifiable {
    public let id: String
    public let service: String
    public let uid: String
    public let connectServer: String?
    public let connectPort: Int?
    public let resource: String?
    public let requireTLS: Bool
    public let autoConnect: Bool
}
