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

    func formatMessage(_ message: ChatMessage) -> String {
        var dict: [String: String] = [
            "type": "message",
            "direction": message.isOutgoing ? "outgoing" : "incoming",
            "from": message.fromJID,
            "body": message.body,
            "timestamp": formatTimestamp(message.timestamp)
        ]
        if message.isDelivered {
            dict["delivered"] = "true"
        }
        if message.isEdited {
            dict["edited"] = "true"
        }
        if let errorText = message.errorText {
            dict["error"] = errorText
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
        case let .connected(jid):
            return encode(["type": "connected", "jid": jid.description, "account": account])
        case let .disconnected(reason):
            return formatDisconnect(reason, account: account)
        case let .authenticationFailed(message):
            return encode(["type": "authentication_failed", "message": message, "account": account])
        case let .messageReceived(message):
            return formatIncomingMessage(message, account: account)
        case .presenceSubscriptionRequest, .deliveryReceiptReceived,
             .messageCorrected, .messageError:
            return formatMiscEvent(event, account: account)
        case .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomSubjectChanged, .roomInviteReceived, .roomMessageReceived:
            return formatMUCEvent(event, account: account)
        case .jingleFileTransferReceived, .jingleFileTransferProgress,
             .jingleFileTransferCompleted, .jingleFileTransferFailed:
            return formatJingleEvent(event, account: account)
        case .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged,
             .presenceUpdated,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .chatMarkerReceived,
             .blockListLoaded, .contactBlocked, .contactUnblocked:
            return nil
        }
    }

    private func formatMiscEvent(_ event: XMPPEvent, account: String) -> String? {
        switch event {
        case let .presenceSubscriptionRequest(from: jid):
            return encode(["type": "subscription_request", "from": jid.description])
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
        case .connected, .disconnected, .authenticationFailed, .messageReceived,
             .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged,
             .presenceUpdated,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .chatMarkerReceived,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomSubjectChanged, .roomInviteReceived, .roomMessageReceived,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .blockListLoaded, .contactBlocked, .contactUnblocked:
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
        }
        return encode(dict)
    }

    private func formatIncomingMessage(_ message: XMPPMessage, account: String) -> String? {
        guard let from = message.from?.bareJID, let body = message.body else { return nil }
        return encode([
            "type": "message", "direction": "incoming", "from": from.description,
            "body": body, "account": account, "timestamp": formatTimestamp(Date())
        ])
    }

    private func formatJingleEvent(_ event: XMPPEvent, account: String) -> String? {
        switch event {
        case let .jingleFileTransferReceived(offer):
            return encode([
                "type": "file_offer",
                "fileName": offer.fileName,
                "fileSize": formatByteCount(offer.fileSize),
                "fileSizeBytes": "\(offer.fileSize)",
                "from": offer.from.bareJID.description,
                "sid": offer.sid,
                "account": account
            ])
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
        case .connected, .disconnected, .authenticationFailed, .messageReceived,
             .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived,
             .chatMarkerReceived, .messageCorrected, .messageError,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomSubjectChanged, .roomInviteReceived, .roomMessageReceived,
             .blockListLoaded, .contactBlocked, .contactUnblocked:
            return nil
        }
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
        case let .roomJoined(room, occupancy):
            return formatRoomJoinedEvent(room: room, occupancy: occupancy, account: account)
        case let .roomOccupantJoined(room, occupant):
            return encode(["type": "room_occupant_joined", "room": room.description, "nickname": occupant.nickname, "account": account])
        case let .roomOccupantLeft(room, occupant):
            return encode(["type": "room_occupant_left", "room": room.description, "nickname": occupant.nickname, "account": account])
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
        case let .roomMessageReceived(message):
            return formatIncomingRoomMessage(message, account: account)
        case .connected, .disconnected, .authenticationFailed, .messageReceived,
             .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived,
             .chatMarkerReceived, .messageCorrected, .messageError,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .blockListLoaded, .contactBlocked, .contactUnblocked:
            return nil
        }
    }

    private func formatRoomJoinedEvent(room: BareJID, occupancy: RoomOccupancy, account: String) -> String {
        var dict: [String: String] = [
            "type": "room_joined", "room": room.description,
            "nickname": occupancy.nickname,
            "participants": "\(occupancy.occupants.count)",
            "account": account
        ]
        if let subject = occupancy.subject {
            dict["subject"] = subject
        }
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

    private func formatIncomingRoomMessage(_ message: XMPPMessage, account: String) -> String? {
        guard let from = message.from, let body = message.body else { return nil }
        let nickname = nicknameFromJID(from)
        return encode([
            "type": "room_message", "direction": "incoming",
            "room": from.bareJID.description, "nickname": nickname,
            "body": body, "account": account,
            "timestamp": formatTimestamp(Date())
        ])
    }

    // MARK: - Private

    private func encode(_ dict: [String: String]) -> String {
        guard let data = try? encoder.encode(dict),
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
