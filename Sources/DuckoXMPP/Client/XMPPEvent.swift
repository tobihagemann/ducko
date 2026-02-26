/// Domain events emitted by ``XMPPClient`` for consumption by higher layers.
public enum XMPPEvent: Sendable {
    case connected(FullJID)
    case disconnected(DisconnectReason)
    case authenticationFailed(String)
    case messageReceived(XMPPMessage)
    case presenceReceived(XMPPPresence)
    case iqReceived(XMPPIQ)
}

/// Reason the client disconnected.
public enum DisconnectReason: Sendable {
    case requested
    case streamError(String)
    case connectionLost(String)
}
