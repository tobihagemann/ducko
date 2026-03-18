/// Domain events emitted by ``XMPPClient`` for consumption by higher layers.
public enum XMPPEvent: Sendable {
    case connected(FullJID)
    case streamResumed(FullJID)
    case disconnected(DisconnectReason)
    case authenticationFailed(String)
    case messageReceived(XMPPMessage)
    case presenceReceived(XMPPPresence)
    case iqReceived(XMPPIQ)
    case rosterLoaded([RosterItem])
    case rosterItemChanged(RosterItem)
    case rosterVersionChanged(String)
    case presenceUpdated(from: JID, presence: XMPPPresence)
    case presenceSubscriptionRequest(from: BareJID)
    case messageCarbonReceived(ForwardedMessage)
    case messageCarbonSent(ForwardedMessage)
    case archivedMessagesLoaded([ArchivedMessage], fin: MAMFin)
    case chatStateChanged(from: BareJID, state: ChatState)
    case deliveryReceiptReceived(messageID: String, from: JID)
    case chatMarkerReceived(messageID: String, type: ChatMarkerType, from: JID)
    case messageCorrected(originalID: String, newBody: String, from: JID)
    case messageRetracted(originalID: String, from: JID)
    case messageModerated(originalID: String, moderator: String, room: BareJID, reason: String?)
    case messageError(messageID: String?, from: JID, error: XMPPStanzaError)

    // MUC (XEP-0045)
    case roomJoined(room: BareJID, occupancy: RoomOccupancy, isNewlyCreated: Bool)
    case roomOccupantJoined(room: BareJID, occupant: RoomOccupant)
    case roomOccupantLeft(room: BareJID, occupant: RoomOccupant, reason: OccupantLeaveReason?)
    case roomOccupantNickChanged(room: BareJID, oldNickname: String, occupant: RoomOccupant)
    case roomSubjectChanged(room: BareJID, subject: String?, setter: JID?)
    case roomInviteReceived(RoomInvite)
    case roomMessageReceived(XMPPMessage)
    case mucPrivateMessageReceived(XMPPMessage)
    case roomDestroyed(room: BareJID, reason: String?, alternateVenue: BareJID?)
    case mucSelfPingFailed(room: BareJID, reason: MUCSelfPingFailure)

    // Jingle File Transfer (XEP-0166/0234)
    case jingleFileTransferReceived(JingleFileOffer)
    case jingleFileTransferCompleted(sid: String)
    case jingleFileTransferFailed(sid: String, reason: String)
    case jingleFileTransferProgress(sid: String, bytesTransferred: Int64, totalBytes: Int64)

    // PEP (XEP-0163)
    case pepItemsPublished(from: BareJID, node: String, items: [PEPItem])
    case pepItemsRetracted(from: BareJID, node: String, itemIDs: [String])

    /// Avatar (XEP-0153 vCard-Based Avatars)
    case vcardAvatarHashReceived(from: BareJID, hash: String?)

    // Blocking (XEP-0191)
    case blockListLoaded([BareJID])
    case contactBlocked(BareJID)
    case contactUnblocked(BareJID)

    // OMEMO (XEP-0384)
    case omemoDeviceListReceived(jid: BareJID, devices: [UInt32])
    case omemoEncryptedMessageReceived(from: JID, decryptedBody: String?, senderDeviceID: UInt32, stanzaID: String?)
    case omemoSessionEstablished(jid: BareJID, deviceID: UInt32, identityKey: [UInt8])
}

/// Reason the client disconnected.
public enum DisconnectReason: Sendable {
    case requested
    case streamError(XMPPStreamError?, text: String?)
    case connectionLost(String)
    case redirect(host: String, port: UInt16?)
}

/// Reason for MUC self-ping failure per XEP-0410.
public enum MUCSelfPingFailure: Sendable {
    case notJoined
    case nickChanged(String)
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
