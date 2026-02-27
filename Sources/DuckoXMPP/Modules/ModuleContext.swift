/// Dependency injection for modules to communicate back to the client.
public struct ModuleContext: Sendable {
    /// Sends a stanza over the connection.
    public let sendStanza: @Sendable (any XMPPStanza) async throws -> Void
    /// Sends an IQ and awaits the matching result/error response. Returns `nil` for IQ errors.
    public let sendIQ: @Sendable (XMPPIQ) async throws -> XMLElement?
    /// Emits a domain event to the client's event stream.
    public let emitEvent: @Sendable (XMPPEvent) -> Void
    /// Generates a unique stanza ID.
    public let generateID: @Sendable () -> String
    /// Returns the connected full JID, or `nil` if not connected.
    public let connectedJID: @Sendable () -> FullJID?
    /// The XMPP domain the client is connected to.
    public let domain: String

    public init(
        sendStanza: @Sendable @escaping (any XMPPStanza) async throws -> Void,
        sendIQ: @Sendable @escaping (XMPPIQ) async throws -> XMLElement?,
        emitEvent: @Sendable @escaping (XMPPEvent) -> Void,
        generateID: @Sendable @escaping () -> String,
        connectedJID: @Sendable @escaping () -> FullJID?,
        domain: String
    ) {
        self.sendStanza = sendStanza
        self.sendIQ = sendIQ
        self.emitEvent = emitEvent
        self.generateID = generateID
        self.connectedJID = connectedJID
        self.domain = domain
    }
}
