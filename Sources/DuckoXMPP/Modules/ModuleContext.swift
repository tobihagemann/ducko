/// Dependency injection for modules to communicate back to the client.
struct ModuleContext: Sendable {
    /// Sends a stanza over the connection.
    let sendStanza: @Sendable (any XMPPStanza) async throws -> Void
    /// Sends an IQ and awaits the matching result/error response. Returns `nil` for IQ errors.
    let sendIQ: @Sendable (XMPPIQ) async throws -> XMLElement?
    /// Emits a domain event to the client's event stream.
    let emitEvent: @Sendable (XMPPEvent) -> Void
    /// Generates a unique stanza ID.
    let generateID: @Sendable () -> String
    /// Returns the connected full JID, or `nil` if not connected.
    let connectedJID: @Sendable () -> FullJID?
}
