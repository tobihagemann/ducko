/// Intercepts stanzas before normal module dispatch.
///
/// Used by features like Stream Management (XEP-0198) that need to
/// see every stanza for ack counting, independent of module routing.
public protocol StanzaInterceptor: AnyObject, Sendable {
    /// Called before dispatching an incoming stanza to modules.
    /// Return `true` to consume the stanza (stop further processing).
    func processIncoming(_ element: XMLElement) -> Bool
    /// Called before sending an outgoing stanza.
    func processOutgoing(_ element: XMLElement)
}
