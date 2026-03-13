/// XEP-0393 Message Styling — advertises support via disco#info.
///
/// This module has no stanza handling; it exists solely to add the
/// `urn:xmpp:styling:0` feature to service discovery responses.
public final class StylingModule: XMPPModule, Sendable {
    public var features: [String] {
        [XMPPNamespaces.styling]
    }

    public init() {}

    public func setUp(_ context: ModuleContext) {}
}
