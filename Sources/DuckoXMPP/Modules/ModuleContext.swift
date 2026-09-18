/// Dependency injection for modules to communicate back to the client.
public struct ModuleContext: Sendable {
    public typealias IQTerminalHandler = @Sendable (Result<XMPPIQ, any Error>) -> Void
    public typealias RosterIQSender = @Sendable (XMPPIQ, @escaping IQTerminalHandler) async throws -> XMLElement?
    /// Sends a stanza over the connection.
    public let sendStanza: @Sendable (any XMPPStanza) async throws -> Void
    /// Sends an IQ and awaits the matching result response. Returns `nil` for result IQs with no child.
    /// Throws ``XMPPStanzaError`` for IQ errors.
    public let sendIQ: @Sendable (XMPPIQ) async throws -> XMLElement?
    public let sendRosterIQ: RosterIQSender
    /// Emits a domain event to the client's event stream.
    public let emitEvent: @Sendable (XMPPEvent) -> Void
    /// Generates a unique stanza ID.
    public let generateID: @Sendable () -> String
    /// Returns the connected full JID, or `nil` if not connected.
    public let connectedJID: @Sendable () -> FullJID?
    /// The XMPP domain the client is connected to.
    public let domain: String
    /// Returns the union of all feature namespaces from registered modules.
    public let availableFeatures: @Sendable () -> Set<String>
    /// Sends a raw XML element over the connection, bypassing interceptors.
    /// Used by StreamManagementModule for protocol-level elements.
    public let sendElement: @Sendable (XMLElement) async throws -> Void
    /// Returns the server's post-auth stream features, or `nil` if not yet available.
    public let serverStreamFeatures: @Sendable () -> XMLElement?

    public init(
        sendStanza: @Sendable @escaping (any XMPPStanza) async throws -> Void,
        sendIQ: @Sendable @escaping (XMPPIQ) async throws -> XMLElement?,
        emitEvent: @Sendable @escaping (XMPPEvent) -> Void,
        generateID: @Sendable @escaping () -> String,
        connectedJID: @Sendable @escaping () -> FullJID?,
        domain: String,
        availableFeatures: @Sendable @escaping () -> Set<String> = { [] },
        sendElement: @Sendable @escaping (XMLElement) async throws -> Void = { _ in },
        serverStreamFeatures: @Sendable @escaping () -> XMLElement? = { nil },
        sendRosterIQ: RosterIQSender? = nil
    ) {
        self.sendStanza = sendStanza
        self.sendIQ = sendIQ
        self.sendRosterIQ = sendRosterIQ ?? { iq, terminal in
            do {
                let child = try await sendIQ(iq)
                var reply = XMPPIQ(type: .result, id: iq.id)
                if let child { reply.element.addChild(child) }
                terminal(.success(reply))
                return child
            } catch {
                terminal(.failure(error))
                throw error
            }
        }
        self.emitEvent = emitEvent
        self.generateID = generateID
        self.connectedJID = connectedJID
        self.domain = domain
        self.availableFeatures = availableFeatures
        self.sendElement = sendElement
        self.serverStreamFeatures = serverStreamFeatures
    }
}
