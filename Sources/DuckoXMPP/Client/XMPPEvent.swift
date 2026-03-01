/// Domain events emitted by ``XMPPClient`` for consumption by higher layers.
public enum XMPPEvent: Sendable {
    case connected(FullJID)
    case disconnected(DisconnectReason)
    case authenticationFailed(String)
    case messageReceived(XMPPMessage)
    case presenceReceived(XMPPPresence)
    case iqReceived(XMPPIQ)
    case rosterLoaded([RosterItem])
    case rosterItemChanged(RosterItem)
    case presenceUpdated(from: JID, presence: XMPPPresence)
    case presenceSubscriptionRequest(from: BareJID)
    case messageCarbonReceived(ForwardedMessage)
    case messageCarbonSent(ForwardedMessage)
    case archivedMessagesLoaded([ArchivedMessage], fin: MAMFin)
    case chatStateChanged(from: BareJID, state: ChatState)
    case deliveryReceiptReceived(messageID: String, from: JID)
    case chatMarkerReceived(messageID: String, type: ChatMarkerType, from: JID)
    case messageCorrected(originalID: String, newBody: String, from: JID)
    case messageError(messageID: String?, from: JID, errorText: String)
}

/// Reason the client disconnected.
public enum DisconnectReason: Sendable {
    case requested
    case streamError(String)
    case connectionLost(String)
}

/// Chat state notification per XEP-0085.
public enum ChatState: String, Sendable, CaseIterable {
    case active
    case composing
    case paused
    case inactive
    case gone
}

/// Chat marker type per XEP-0333.
public enum ChatMarkerType: String, Sendable, CaseIterable {
    case received
    case displayed
    case acknowledged
}
