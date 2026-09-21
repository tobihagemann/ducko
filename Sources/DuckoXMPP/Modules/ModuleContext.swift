/// Dependency injection for modules to communicate back to the client.
public struct ModuleContext: Sendable {
    public typealias IQTerminalHandler = @Sendable (Result<XMPPIQ, any Error>) -> Void
    public typealias IQSender = @Sendable (XMPPIQ, IQTerminalHandler?) async throws -> XMLElement?
    /// Sends a stanza over the connection.
    public let sendStanza: @Sendable (any XMPPStanza) async throws -> Void
    private let sendIQImpl: IQSender
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
        sendIQ: @escaping IQSender,
        emitEvent: @Sendable @escaping (XMPPEvent) -> Void,
        generateID: @Sendable @escaping () -> String,
        connectedJID: @Sendable @escaping () -> FullJID?,
        domain: String,
        availableFeatures: @Sendable @escaping () -> Set<String> = { [] },
        sendElement: @Sendable @escaping (XMLElement) async throws -> Void = { _ in },
        serverStreamFeatures: @Sendable @escaping () -> XMLElement? = { nil }
    ) {
        self.sendStanza = sendStanza
        self.sendIQImpl = sendIQ
        self.emitEvent = emitEvent
        self.generateID = generateID
        self.connectedJID = connectedJID
        self.domain = domain
        self.availableFeatures = availableFeatures
        self.sendElement = sendElement
        self.serverStreamFeatures = serverStreamFeatures
    }

    /// Sends an IQ and awaits the matching result response. Returns `nil` for result IQs with no child.
    /// Throws ``XMPPStanzaError`` for IQ errors. `onTerminal` runs exactly once with the outcome, before the caller
    /// resumes. The `sendIQ` closure passed to `init` must uphold this.
    public func sendIQ(_ iq: XMPPIQ, onTerminal: IQTerminalHandler? = nil) async throws -> XMLElement? {
        try await sendIQImpl(iq, onTerminal)
    }
}
