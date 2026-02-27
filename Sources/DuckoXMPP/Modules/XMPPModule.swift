/// A feature module that handles specific XMPP stanza types.
///
/// Modules are `final class` (not actor) to keep handler calls synchronous from the dispatch loop.
/// The ``ModuleContext`` is stored behind an `OSAllocatedUnfairLock` for `Sendable` compliance.
public protocol XMPPModule: AnyObject, Sendable {
    /// XMPP feature namespaces this module supports (for XEP-0030 Service Discovery).
    var features: [String] { get }
    /// Called once when the module is registered with a client.
    func setUp(_ context: ModuleContext)
    /// Called after the XMPP session is fully established.
    func handleConnect() async throws
    /// Called when the XMPP session is torn down (before state is cleared).
    func handleDisconnect() async
    /// Called for each incoming `<message>` stanza.
    func handleMessage(_ message: XMPPMessage) throws
    /// Called for each incoming `<presence>` stanza.
    func handlePresence(_ presence: XMPPPresence) throws
    /// Called for each incoming `<iq>` stanza (after IQ tracking).
    func handleIQ(_ iq: XMPPIQ) throws
}

/// Default no-op implementations.
public extension XMPPModule {
    var features: [String] {
        []
    }

    func handleConnect() async throws {}
    func handleDisconnect() async {}
    func handleMessage(_ message: XMPPMessage) throws {}
    func handlePresence(_ presence: XMPPPresence) throws {}
    func handleIQ(_ iq: XMPPIQ) throws {}
}
