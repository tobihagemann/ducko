import DuckoCore
import DuckoXMPP
import Foundation

struct JSONFormatter: CLIFormatter {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    // MARK: - CLIFormatter

    func formatMessage(_ message: ChatMessage, accountJID: BareJID? = nil) -> String {
        var dict: [String: String] = [
            "type": "message",
            "direction": message.isOutgoing ? "outgoing" : "incoming",
            "from": message.fromJID,
            "body": message.body,
            "timestamp": formatTimestamp(message.timestamp)
        ]
        if message.body.hasPrefix("/me ") {
            dict["action"] = "true"
            if message.isOutgoing, let accountJID {
                dict["actor"] = accountJID.description
            }
        }
        if message.isDelivered {
            dict["delivered"] = "true"
        }
        if message.isEncrypted {
            dict["encrypted"] = "true"
        }
        if message.isEdited {
            dict["edited"] = "true"
        }
        if let errorText = message.errorText {
            dict["error"] = errorText
        }
        let extraAttachments = message.attachments.filter { $0.url != message.body }
        if !extraAttachments.isEmpty {
            dict["attachments"] = extraAttachments.map(\.url).joined(separator: ",")
        }
        return encode(dict)
    }

    func formatAccount(_ account: Account) -> String {
        encode([
            "type": "account",
            "id": account.id.uuidString,
            "jid": account.jid.description,
            "isEnabled": account.isEnabled ? "true" : "false"
        ])
    }

    func formatContactWithPresence(_ contact: Contact, presence: PresenceService.PresenceStatus?) -> String {
        var dict: [String: String] = [
            "type": "contact",
            "jid": contact.jid.description,
            "subscription": contact.subscription.rawValue,
            "presence": (presence ?? .offline).rawValue
        ]
        if let name = contact.name {
            dict["name"] = name
        }
        if let localAlias = contact.localAlias {
            dict["localAlias"] = localAlias
        }
        if !contact.groups.isEmpty {
            dict["groups"] = contact.groups.joined(separator: ",")
        }
        return encode(dict)
    }

    func formatGroupHeader(_ group: ContactGroup) -> String {
        encode([
            "type": "group_header",
            "name": group.name,
            "count": "\(group.contacts.count)"
        ])
    }

    func formatPresence(jid: BareJID, status: String, message: String?) -> String {
        var dict: [String: String] = [
            "type": "presence",
            "jid": jid.description,
            "status": status
        ]
        if let message {
            dict["message"] = message
        }
        return encode(dict)
    }

    func formatError(_ error: any Error) -> String {
        encode([
            "type": "error",
            "message": error.localizedDescription
        ])
    }

    func formatEvent(_ event: XMPPEvent, accountID: UUID) -> String? {
        let account = accountID.uuidString
        switch event {
        case .connected, .streamResumed, .disconnected, .authenticationFailed:
            return formatConnectionEvent(event, account: account)
        case let .messageReceived(message):
            return formatIncomingMessage(message, account: account)
        case let .messageCarbonReceived(forwarded):
            return formatCarbonEvent(forwarded, isOutgoing: false, account: account)
        case let .messageCarbonSent(forwarded):
            return formatCarbonEvent(forwarded, isOutgoing: true, account: account)
        case .presenceSubscriptionRequest, .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .deliveryReceiptReceived,
             .messageCorrected, .messageRetracted, .messageModerated, .messageError:
            return formatMiscEvent(event, account: account)
        case .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged, .roomSubjectChanged,
             .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived, .roomDestroyed,
             .mucSelfPingFailed:
            return formatMUCEvent(event, account: account)
        case .jingleFileTransferReceived, .jingleFileRequestReceived,
             .jingleFileTransferProgress, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleChecksumMismatch,
             .jingleContentAddReceived, .jingleContentAccepted, .jingleContentRejected, .jingleContentRemoved,
             .oobIQOfferReceived:
            return formatJingleEvent(event, account: account)
        case let .serviceOutageReceived(info):
            return formatOutageEvent(info, account: account)
        case .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated,
             .archivedMessagesLoaded,
             .chatStateChanged, .chatMarkerReceived,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .jingleChecksumReceived,
             .blockListLoaded, .contactBlocked, .contactUnblocked:
            return nil
        case .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced:
            return formatOMEMOEvent(event, account: account)
        }
    }

    private func formatOMEMOEvent(_ event: XMPPEvent, account: String) -> String? {
        switch event {
        case let .omemoDeviceListReceived(jid, devices):
            return encode([
                "type": "omemo_device_list",
                "jid": jid.description,
                "devices": devices.map(String.init).joined(separator: ","),
                "account": account
            ])
        case let .omemoSessionEstablished(jid, deviceID, identityKey):
            let fingerprint = identityKey.map { String(format: "%02x", $0) }.joined()
            return encode([
                "type": "omemo_session_established",
                "jid": jid.description,
                "deviceID": "\(deviceID)",
                "fingerprint": fingerprint,
                "account": account
            ])
        case .omemoEncryptedMessageReceived, .omemoSessionAdvanced:
            return nil
        case .connected, .streamResumed, .disconnected, .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived,
             .chatMarkerReceived, .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged,
             .roomSubjectChanged, .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived,
             .roomDestroyed, .mucSelfPingFailed,
             .jingleFileTransferReceived, .jingleFileRequestReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .jingleChecksumReceived, .jingleChecksumMismatch,
             .jingleContentAddReceived, .jingleContentAccepted, .jingleContentRejected, .jingleContentRemoved,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .oobIQOfferReceived, .serviceOutageReceived:
            return nil
        }
    }

    private func formatConnectionEvent(_ event: XMPPEvent, account: String) -> String? {
        switch event {
        case let .connected(jid):
            return encode(["type": "connected", "jid": jid.description, "account": account])
        case let .streamResumed(jid):
            return encode(["type": "stream_resumed", "jid": jid.description, "account": account])
        case let .disconnected(reason):
            return formatDisconnect(reason, account: account)
        case let .authenticationFailed(message):
            return encode(["type": "authentication_failed", "message": message, "account": account])
        case .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived,
             .chatMarkerReceived, .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged,
             .roomSubjectChanged, .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived,
             .roomDestroyed, .mucSelfPingFailed,
             .jingleFileTransferReceived, .jingleFileRequestReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .jingleChecksumReceived, .jingleChecksumMismatch,
             .jingleContentAddReceived, .jingleContentAccepted, .jingleContentRejected, .jingleContentRemoved,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced,
             .oobIQOfferReceived, .serviceOutageReceived:
            return nil
        }
    }

    private func formatCarbonEvent(_ forwarded: ForwardedMessage, isOutgoing: Bool, account: String) -> String? {
        let jid = isOutgoing ? forwarded.message.to?.bareJID : forwarded.message.from?.bareJID
        let oob = forwarded.message.oobData
        let body = forwarded.message.body ?? oob.first?.url
        guard let jid, let body else { return nil }
        let jidKey = isOutgoing ? "to" : "from"
        let direction = isOutgoing ? "outgoing" : "incoming"
        var dict: [String: String] = [
            "type": "message", "direction": direction, "carbon": "true",
            jidKey: jid.description, "body": body,
            "account": account, "timestamp": formatTimestamp(Date())
        ]
        if body.hasPrefix("/me ") {
            dict["action"] = "true"
        }
        let extraOOB = oob.filter { $0.url != body }
        if !extraOOB.isEmpty {
            dict["attachments"] = extraOOB.map(\.url).joined(separator: ",")
        }
        return encode(dict)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func formatMiscEvent(_ event: XMPPEvent, account: String) -> String? {
        switch event {
        case let .presenceSubscriptionRequest(from: jid):
            return encode(["type": "subscription_request", "from": jid.description])
        case let .presenceSubscriptionApproved(from: jid):
            return encode(["type": "subscription_approved", "from": jid.description])
        case let .presenceSubscriptionRevoked(from: jid):
            return encode(["type": "subscription_revoked", "from": jid.description])
        case let .deliveryReceiptReceived(messageID, from):
            return encode(["type": "delivery_receipt", "messageID": messageID, "from": from.bareJID.description, "account": account])
        case let .messageCorrected(originalID, newBody, from):
            return encode(["type": "message_corrected", "originalID": originalID, "newBody": newBody, "from": from.bareJID.description, "account": account])
        case let .messageError(_, from, error):
            var dict: [String: String] = [
                "type": "message_error",
                "from": from.bareJID.description,
                "condition": error.condition.rawValue,
                "account": account
            ]
            if let text = error.text { dict["text"] = text }
            return encode(dict)
        case let .messageRetracted(originalID, from):
            return encode(["type": "message_retracted", "original_id": originalID, "from": from.bareJID.description, "account": account])
        case let .messageModerated(originalID, moderator, room, reason):
            var dict: [String: String] = ["type": "message_moderated", "original_id": originalID, "moderator": moderator, "room": room.description, "account": account]
            if let reason { dict["reason"] = reason }
            return encode(dict)
        case .connected, .streamResumed, .disconnected, .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .chatMarkerReceived,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged,
             .roomSubjectChanged, .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived,
             .roomDestroyed, .mucSelfPingFailed,
             .jingleFileTransferReceived, .jingleFileRequestReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .jingleChecksumReceived, .jingleChecksumMismatch,
             .jingleContentAddReceived, .jingleContentAccepted, .jingleContentRejected, .jingleContentRemoved,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced,
             .oobIQOfferReceived, .serviceOutageReceived:
            return nil
        }
    }

    private func formatDisconnect(_ reason: DisconnectReason, account: String) -> String {
        var dict: [String: String] = ["type": "disconnected", "account": account]
        switch reason {
        case .requested:
            dict["reason"] = "requested"
        case let .streamError(condition, text):
            dict["reason"] = "stream_error"
            if let condition { dict["condition"] = condition.rawValue }
            if let text { dict["text"] = text }
        case let .connectionLost(message):
            dict["reason"] = "connection_lost"
            dict["message"] = message
        case let .redirect(host, port):
            dict["reason"] = "redirect"
            dict["host"] = host
            if let port { dict["port"] = "\(port)" }
        }
        return encode(dict)
    }

    private func formatIncomingMessage(_ message: XMPPMessage, account: String) -> String? {
        guard let from = message.from?.bareJID else { return nil }
        let oob = message.oobData
        let body = message.body ?? oob.first?.url
        guard let body else { return nil }
        var dict: [String: String] = [
            "type": "message", "direction": "incoming", "from": from.description,
            "body": body, "account": account, "timestamp": formatTimestamp(Date())
        ]
        if body.hasPrefix("/me ") {
            dict["action"] = "true"
        }
        let extraOOB = oob.filter { $0.url != body }
        if !extraOOB.isEmpty {
            dict["attachments"] = extraOOB.map(\.url).joined(separator: ",")
        }
        return encode(dict)
    }

    // swiftlint:disable:next function_body_length
    private func formatJingleEvent(_ event: XMPPEvent, account: String) -> String? {
        switch event {
        case let .jingleFileTransferReceived(offer):
            return formatFileOfferEvent(offer, account: account)
        case let .jingleFileRequestReceived(request):
            return formatFileRequest(request, account: account)
        case let .jingleFileTransferProgress(sid, bytesTransferred, totalBytes):
            let (progress, _) = jingleProgressState(bytesTransferred: bytesTransferred, totalBytes: totalBytes)
            return encode([
                "type": "jingle_transfer_progress",
                "sid": sid,
                "progress": "\(Int(progress * 100))",
                "bytesTransferred": "\(bytesTransferred)",
                "totalBytes": "\(totalBytes)",
                "account": account
            ])
        case let .jingleFileTransferCompleted(sid):
            return encode(["type": "jingle_transfer_completed", "sid": sid, "account": account])
        case let .jingleFileTransferFailed(sid, reason):
            return encode(["type": "jingle_transfer_failed", "sid": sid, "reason": reason, "account": account])
        case let .jingleChecksumMismatch(sid, expected, computed):
            return encode([
                "type": "jingle_checksum_mismatch", "sid": sid,
                "expected": expected, "computed": computed, "account": account
            ])
        case let .jingleContentAddReceived(sid, contentName, offer):
            return encode([
                "type": "jingle_content_add",
                "sid": sid,
                "contentName": contentName,
                "fileName": offer.fileName,
                "fileSizeBytes": "\(offer.fileSize)",
                "from": offer.from.bareJID.description,
                "account": account
            ])
        case let .oobIQOfferReceived(offer):
            return formatOOBIQOfferEvent(offer, account: account)
        case .jingleChecksumReceived,
             .jingleContentAccepted, .jingleContentRejected, .jingleContentRemoved,
             .connected, .streamResumed, .disconnected, .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived,
             .chatMarkerReceived, .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged,
             .roomSubjectChanged, .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived,
             .roomDestroyed, .mucSelfPingFailed,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced,
             .serviceOutageReceived:
            return nil
        }
    }

    private func formatOOBIQOfferEvent(_ offer: OOBIQOffer, account: String) -> String {
        var dict: [String: String] = [
            "type": "oob_iq_offer",
            "id": offer.id,
            "url": offer.url,
            "from": offer.from.bareJID.description,
            "account": account
        ]
        if let desc = offer.desc { dict["desc"] = desc }
        return encode(dict)
    }

    private func formatOutageEvent(_ info: ServiceOutageInfo, account: String) -> String {
        var dict: [String: String] = ["type": "service_outage", "account": account]
        if let desc = info.description { dict["description"] = desc }
        if let end = info.expectedEnd { dict["expected_end"] = end }
        if let alt = info.alternativeDomain { dict["alternative_domain"] = alt }
        return encode(dict)
    }

    func formatTransferProgress(fileName: String, fileSize: Int64, progress: Double) -> String {
        encode([
            "type": "transfer_progress",
            "fileName": fileName,
            "fileSize": formatByteCount(fileSize),
            "progress": "\(Int(progress * 100))"
        ])
    }

    func formatFileMessage(fileName: String, url: String, fileSize: Int64?) -> String {
        var dict: [String: String] = [
            "type": "file",
            "fileName": fileName,
            "url": url
        ]
        if let fileSize {
            dict["fileSize"] = formatByteCount(fileSize)
            dict["fileSizeBytes"] = "\(fileSize)"
        }
        return encode(dict)
    }

    private func formatFileOfferEvent(_ offer: JingleFileOffer, account: String) -> String {
        encode([
            "type": "file_offer",
            "fileName": offer.fileName,
            "fileSize": formatByteCount(offer.fileSize),
            "fileSizeBytes": "\(offer.fileSize)",
            "from": offer.from.bareJID.description,
            "sid": offer.sid,
            "account": account
        ])
    }

    private func formatFileRequest(_ request: JingleFileRequest, account: String) -> String {
        encode([
            "type": "file_request",
            "fileName": request.fileDescription.name,
            "fileSize": formatByteCount(request.fileDescription.size),
            "fileSizeBytes": "\(request.fileDescription.size)",
            "from": request.from.bareJID.description,
            "sid": request.sid,
            "account": account
        ])
    }

    func formatFileOffer(fileName: String, fileSize: Int64, from: String, sid: String) -> String {
        encode([
            "type": "file_offer",
            "fileName": fileName,
            "fileSize": formatByteCount(fileSize),
            "fileSizeBytes": "\(fileSize)",
            "from": from,
            "sid": sid
        ])
    }

    func formatJingleTransferProgress(fileName: String, fileSize: Int64, progress: Double, state: String) -> String {
        encode([
            "type": "jingle_transfer_progress",
            "fileName": fileName,
            "fileSize": formatByteCount(fileSize),
            "progress": "\(Int(progress * 100))",
            "state": state
        ])
    }

    func formatJingleTransferCompleted(sid: String) -> String {
        encode([
            "type": "jingle_transfer_completed",
            "sid": sid
        ])
    }

    func formatJingleTransferFailed(sid: String, reason: String) -> String {
        encode([
            "type": "jingle_transfer_failed",
            "sid": sid,
            "reason": reason
        ])
    }

    func formatTypingIndicator(from jid: BareJID, state: ChatState) -> String? {
        encode([
            "type": "typing",
            "jid": jid.description,
            "state": state.rawValue
        ])
    }

    // MARK: - Room Formatting

    func formatRoom(_ room: DiscoveredRoom) -> String {
        var dict: [String: String] = [
            "type": "room",
            "jid": room.jidString
        ]
        if let name = room.name {
            dict["name"] = name
        }
        return encode(dict)
    }

    func formatBookmark(_ bookmark: RoomBookmark) -> String {
        var dict: [String: String] = [
            "type": "bookmark",
            "jid": bookmark.jidString,
            "autojoin": bookmark.autojoin ? "true" : "false"
        ]
        if let name = bookmark.name { dict["name"] = name }
        if let nick = bookmark.nickname { dict["nickname"] = nick }
        return encode(dict)
    }

    func formatRoomParticipant(_ participant: RoomParticipant) -> String {
        var dict: [String: String] = [
            "type": "room_participant",
            "nickname": participant.nickname,
            "role": participant.role.rawValue,
            "affiliation": participant.affiliation.rawValue
        ]
        if let jid = participant.jidString {
            dict["jid"] = jid
        }
        return encode(dict)
    }

    func formatRoomParticipantGroupHeader(_ group: RoomParticipantGroup) -> String {
        encode([
            "type": "room_participant_group",
            "affiliation": group.affiliation.displayName,
            "count": "\(group.participants.count)"
        ])
    }

    func formatRoomJoinedConfirmation(room: String, nickname: String, participantCount: Int, subject: String?) -> String {
        var dict: [String: String] = [
            "type": "room_joined",
            "room": room,
            "nickname": nickname,
            "participants": "\(participantCount)"
        ]
        if let subject, !subject.isEmpty {
            dict["subject"] = subject
        }
        return encode(dict)
    }

    private func formatMUCEvent(_ event: XMPPEvent, account: String) -> String? {
        switch event {
        case let .roomJoined(room, occupancy, isNewlyCreated):
            return formatRoomJoinedEvent(room: room, occupancy: occupancy, isNewlyCreated: isNewlyCreated, account: account)
        case let .roomOccupantJoined(room, occupant):
            return encode(["type": "room_occupant_joined", "room": room.description, "nickname": occupant.nickname, "account": account])
        case let .roomOccupantLeft(room, occupant, reason):
            return formatOccupantLeftEvent(room: room, occupant: occupant, reason: reason, account: account)
        case let .roomOccupantNickChanged(room, oldNickname, occupant):
            return encode(["type": "room_nick_changed", "room": room.description, "old_nickname": oldNickname, "new_nickname": occupant.nickname, "account": account])
        case let .roomSubjectChanged(room, subject, setter):
            return formatRoomSubjectEvent(room: room, subject: subject, setter: setter, account: account)
        case let .roomInviteReceived(invite):
            var dict: [String: String] = [
                "type": "room_invite",
                "room": invite.room.description,
                "from": invite.from.bareJID.description,
                "account": account
            ]
            if let reason = invite.reason { dict["reason"] = reason }
            return encode(dict)
        case let .roomMessageReceived(message), let .mucPrivateMessageReceived(message):
            return formatMUCMessage(event, message: message, account: account)
        case let .roomDestroyed(room, reason, alternate):
            return formatRoomDestroyedEvent(room: room, reason: reason, alternate: alternate, account: account)
        case .mucSelfPingFailed,
             .connected, .streamResumed, .disconnected, .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived,
             .chatMarkerReceived, .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .jingleFileTransferReceived, .jingleFileRequestReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .jingleChecksumReceived, .jingleChecksumMismatch,
             .jingleContentAddReceived, .jingleContentAccepted, .jingleContentRejected, .jingleContentRemoved,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced,
             .oobIQOfferReceived, .serviceOutageReceived:
            return nil
        }
    }

    private func formatRoomJoinedEvent(room: BareJID, occupancy: RoomOccupancy, isNewlyCreated: Bool, account: String) -> String {
        var dict: [String: String] = [
            "type": "room_joined", "room": room.description,
            "nickname": occupancy.nickname,
            "participants": "\(occupancy.occupants.count)",
            "account": account
        ]
        if isNewlyCreated {
            dict["newly_created"] = "true"
        }
        if occupancy.flags.contains(.nonAnonymous) {
            dict["non_anonymous"] = "true"
        }
        if occupancy.flags.contains(.logged) {
            dict["logged"] = "true"
        }
        if let subject = occupancy.subject {
            dict["subject"] = subject
        }
        return encode(dict)
    }

    private func formatOccupantLeftEvent(room: BareJID, occupant: RoomOccupant, reason: OccupantLeaveReason?, account: String) -> String {
        var dict: [String: String] = [
            "type": "room_occupant_left",
            "room": room.description,
            "nickname": occupant.nickname,
            "account": account
        ]
        switch reason {
        case let .kicked(r):
            dict["leave_reason"] = "kicked"
            if let r { dict["reason_text"] = r }
        case let .banned(r):
            dict["leave_reason"] = "banned"
            if let r { dict["reason_text"] = r }
        case let .affiliationChanged(r):
            dict["leave_reason"] = "affiliation_changed"
            if let r { dict["reason_text"] = r }
        case .serviceShutdown:
            dict["leave_reason"] = "service_shutdown"
        case nil:
            break
        }
        return encode(dict)
    }

    private func formatRoomDestroyedEvent(room: BareJID, reason: String?, alternate: BareJID?, account: String) -> String {
        var dict: [String: String] = [
            "type": "room_destroyed",
            "room": room.description,
            "account": account
        ]
        if let reason { dict["reason"] = reason }
        if let alternate { dict["alternate"] = alternate.description }
        return encode(dict)
    }

    private func formatRoomSubjectEvent(room: BareJID, subject: String?, setter: JID?, account: String) -> String {
        var dict: [String: String] = [
            "type": "room_subject_changed",
            "room": room.description,
            "account": account
        ]
        if let subject { dict["subject"] = subject }
        if let setter { dict["setter"] = setter.bareJID.description }
        return encode(dict)
    }

    private func formatMUCMessage(_ event: XMPPEvent, message: XMPPMessage, account: String) -> String? {
        if case .mucPrivateMessageReceived = event {
            return formatIncomingPrivateMessage(message, account: account)
        }
        return formatIncomingRoomMessage(message, account: account)
    }

    private func formatIncomingRoomMessage(_ message: XMPPMessage, account: String) -> String? {
        guard let from = message.from else { return nil }
        let oob = message.oobData
        let body = message.body ?? oob.first?.url
        guard let body else { return nil }
        let nickname = nicknameFromJID(from)
        var dict: [String: String] = [
            "type": "room_message", "direction": "incoming",
            "room": from.bareJID.description, "nickname": nickname,
            "body": body, "account": account,
            "timestamp": formatTimestamp(Date())
        ]
        if body.hasPrefix("/me ") {
            dict["action"] = "true"
        }
        let extraOOB = oob.filter { $0.url != body }
        if !extraOOB.isEmpty {
            dict["attachments"] = extraOOB.map(\.url).joined(separator: ",")
        }
        return encode(dict)
    }

    private func formatIncomingPrivateMessage(_ message: XMPPMessage, account: String) -> String? {
        guard let from = message.from else { return nil }
        let oob = message.oobData
        let body = message.body ?? oob.first?.url
        guard let body else { return nil }
        let nickname = nicknameFromJID(from)
        var dict: [String: String] = [
            "type": "muc_private_message", "direction": "incoming",
            "room": from.bareJID.description, "nickname": nickname,
            "body": body, "account": account,
            "timestamp": formatTimestamp(Date())
        ]
        if body.hasPrefix("/me ") {
            dict["action"] = "true"
        }
        let extraOOB = oob.filter { $0.url != body }
        if !extraOOB.isEmpty {
            dict["attachments"] = extraOOB.map(\.url).joined(separator: ",")
        }
        return encode(dict)
    }

    func formatTLSInfo(_ info: TLSInfo) -> String {
        var dict: [String: String] = [
            "type": "tls_info",
            "tls_version": info.protocolVersion,
            "cipher_suite": info.cipherSuite
        ]
        if let subject = info.certificateSubject { dict["subject"] = subject }
        if let issuer = info.certificateIssuer { dict["issuer"] = issuer }
        if let expiry = info.certificateExpiry { dict["expires"] = formatTimestamp(expiry) }
        if let fingerprint = info.certificateSHA256 { dict["sha256"] = fingerprint }
        return encode(dict)
    }

    func formatServerInfo(_ info: ServerInfo) -> String {
        var dict = ["type": "server_info"]
        for address in info.contactAddresses {
            let key = address.type.rawValue
            if let existing = dict[key] {
                dict[key] = existing + "," + address.address
            } else {
                dict[key] = address.address
            }
        }
        return encode(dict)
    }

    func formatSearchedChannel(_ channel: SearchedChannel) -> String {
        var dict: [String: String] = [
            "type": "searched_channel",
            "jid": channel.jidString
        ]
        if let name = channel.name { dict["name"] = name }
        if let userCount = channel.userCount { dict["users"] = "\(userCount)" }
        if let isOpen = channel.isOpen { dict["is_open"] = isOpen ? "true" : "false" }
        if let description = channel.description { dict["description"] = description }
        return encode(dict)
    }

    func formatProfile(_ profile: ProfileInfo) -> String {
        var json = ProfileJSON()
        json.fullName = profile.fullName
        json.nickname = profile.nickname
        json.givenName = profile.givenName
        json.familyName = profile.familyName
        json.organization = profile.organization
        json.title = profile.title
        json.role = profile.role
        let emailAddresses = profile.emails.map(\.address).filter { !$0.isEmpty }
        if !emailAddresses.isEmpty { json.emails = emailAddresses }
        let phoneNumbers = profile.telephones.map(\.number).filter { !$0.isEmpty }
        if !phoneNumbers.isEmpty { json.phones = phoneNumbers }
        json.url = profile.url
        json.birthday = profile.birthday
        json.note = profile.note
        return encode(json)
    }

    private struct ProfileJSON: Encodable {
        var type = "profile"
        var fullName: String?
        var nickname: String?
        var givenName: String?
        var familyName: String?
        var organization: String?
        var title: String?
        var role: String?
        var emails: [String]?
        var phones: [String]?
        var url: String?
        var birthday: String?
        var note: String?

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encodeIfPresent(fullName, forKey: .fullName)
            try container.encodeIfPresent(nickname, forKey: .nickname)
            try container.encodeIfPresent(givenName, forKey: .givenName)
            try container.encodeIfPresent(familyName, forKey: .familyName)
            try container.encodeIfPresent(organization, forKey: .organization)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(role, forKey: .role)
            try container.encodeIfPresent(emails, forKey: .emails)
            try container.encodeIfPresent(phones, forKey: .phones)
            try container.encodeIfPresent(url, forKey: .url)
            try container.encodeIfPresent(birthday, forKey: .birthday)
            try container.encodeIfPresent(note, forKey: .note)
        }

        private enum CodingKeys: String, CodingKey {
            case type, fullName, nickname, givenName, familyName
            case organization, title, role, emails, phones, url, birthday, note
        }
    }

    // MARK: - Private

    private func encode(_ value: some Encodable) -> String {
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    /// ISO 8601 without fractional seconds for cleaner JSON output.
    private func formatTimestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }
}
