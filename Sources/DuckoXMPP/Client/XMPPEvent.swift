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
    case messageError(messageID: String?, from: JID, error: XMPPStanzaError)

    // MUC (XEP-0045)
    case roomJoined(room: BareJID, occupancy: RoomOccupancy)
    case roomOccupantJoined(room: BareJID, occupant: RoomOccupant)
    case roomOccupantLeft(room: BareJID, occupant: RoomOccupant)
    case roomSubjectChanged(room: BareJID, subject: String?, setter: JID?)
    case roomInviteReceived(RoomInvite)
    case roomMessageReceived(XMPPMessage)

    // Jingle File Transfer (XEP-0166/0234)
    case jingleFileTransferReceived(JingleFileOffer)
    case jingleFileTransferCompleted(sid: String)
    case jingleFileTransferFailed(sid: String, reason: String)
    case jingleFileTransferProgress(sid: String, bytesTransferred: Int64, totalBytes: Int64)

    // Blocking (XEP-0191)
    case blockListLoaded([BareJID])
    case contactBlocked(BareJID)
    case contactUnblocked(BareJID)
}

/// Reason the client disconnected.
public enum DisconnectReason: Sendable {
    case requested
    case streamError(XMPPStreamError?, text: String?)
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
