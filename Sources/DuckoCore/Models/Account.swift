import DuckoXMPP
import Foundation

public struct Account: Sendable, Identifiable {
    public var id: UUID
    public var jid: BareJID
    public var displayName: String?
    public var isEnabled: Bool
    public var connectOnLaunch: Bool
    public var host: String?
    public var port: Int?
    public var resource: String?
    public var requireTLS: Bool
    public var rosterVersion: String?
    public var createdAt: Date

    public init(
        id: UUID,
        jid: BareJID,
        displayName: String? = nil,
        isEnabled: Bool,
        connectOnLaunch: Bool,
        host: String? = nil,
        port: Int? = nil,
        resource: String? = nil,
        requireTLS: Bool = true,
        rosterVersion: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.jid = jid
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.connectOnLaunch = connectOnLaunch
        self.host = host
        self.port = port
        self.resource = resource
        self.requireTLS = requireTLS
        self.rosterVersion = rosterVersion
        self.createdAt = createdAt
    }
}

public typealias TLSInfo = DuckoXMPP.TLSInfo
