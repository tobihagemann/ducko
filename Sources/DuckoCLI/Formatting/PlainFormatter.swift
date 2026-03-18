import DuckoCore
import DuckoXMPP
import Foundation

struct PlainFormatter: CLIFormatter {
    func formatMessage(_ message: ChatMessage, accountJID: BareJID? = nil) -> String {
        let timestamp = iso8601(message.timestamp)
        let direction = message.isOutgoing ? "->" : "<-"
        let displayJID = message.isOutgoing ? (accountJID?.description ?? message.fromJID) : message.fromJID
        let body = if message.body.hasPrefix("/me ") {
            "* \(displayJID) \(message.body.dropFirst(4))"
        } else {
            "\(message.fromJID): \(message.body)"
        }
        var line = "[\(timestamp)] \(direction) \(body)"
        if message.isEncrypted {
            line += " [encrypted]"
        }
        if message.isEdited {
            line += " [edited]"
        }
        if message.isOutgoing, message.isDelivered {
            line += " [delivered]"
        }
        if let errorText = message.errorText {
            line += " [error: \(errorText)]"
        }
        return line
    }

    func formatAccount(_ account: Account) -> String {
        "\(account.jid) (\(account.id))"
    }

    func formatContactWithPresence(_ contact: Contact, presence: PresenceService.PresenceStatus?) -> String {
        let indicator = switch presence {
        case .available:
            "[+]"
        case .away, .xa:
            "[~]"
        case .dnd:
            "[-]"
        case .offline, .none:
            "[ ]"
        }
        let displayName = contact.localAlias ?? contact.name ?? contact.jid.description
        return "\(indicator) \(displayName) (\(contact.jid)) [\(contact.subscription.rawValue)]"
    }

    func formatGroupHeader(_ group: ContactGroup) -> String {
        "--- \(group.name) (\(group.contacts.count)) ---"
    }

    func formatPresence(jid: BareJID, status: String, message: String?) -> String {
        if let message {
            return "\(jid) is \(status): \(message)"
        }
        return "\(jid) is \(status)"
    }

    func formatError(_ error: any Error) -> String {
        "error: \(error.localizedDescription)"
    }

    func formatEvent(_ event: XMPPEvent, accountID: UUID) -> String? {
        switch event {
        case .connected, .streamResumed, .disconnected, .authenticationFailed:
            return formatConnectionEvent(event)
        case let .messageReceived(message):
            return formatIncomingMessage(message)
        case let .messageCarbonReceived(forwarded):
            return formatCarbonEvent(forwarded, isOutgoing: false)
        case let .messageCarbonSent(forwarded):
            return formatCarbonEvent(forwarded, isOutgoing: true)
        case .presenceSubscriptionRequest, .deliveryReceiptReceived,
             .messageCorrected, .messageRetracted, .messageModerated, .messageError:
            return formatMiscEvent(event)
        case .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged, .roomSubjectChanged,
             .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived, .roomDestroyed,
             .mucSelfPingFailed:
            return formatMUCEvent(event)
        case .jingleFileTransferReceived, .jingleFileTransferProgress,
             .jingleFileTransferCompleted, .jingleFileTransferFailed:
            return formatJingleEvent(event)
        case .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated,
             .archivedMessagesLoaded,
             .chatStateChanged, .chatMarkerReceived,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .blockListLoaded, .contactBlocked, .contactUnblocked:
            return nil
        case .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced:
            return formatOMEMOEvent(event)
        }
    }

    private func formatOMEMOEvent(_ event: XMPPEvent) -> String? {
        switch event {
        case let .omemoDeviceListReceived(jid, devices):
            return "OMEMO devices for \(jid): \(devices.map(String.init).joined(separator: ", "))"
        case let .omemoSessionEstablished(jid, deviceID, _):
            return "OMEMO session established with \(jid) device \(deviceID)"
        case .omemoEncryptedMessageReceived, .omemoSessionAdvanced:
            return nil
        case .connected, .streamResumed, .disconnected, .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
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
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .blockListLoaded, .contactBlocked, .contactUnblocked:
            return nil
        }
    }

    private func formatConnectionEvent(_ event: XMPPEvent) -> String? {
        switch event {
        case let .connected(jid):
            return "connected as \(jid)"
        case let .streamResumed(jid):
            return "stream resumed as \(jid)"
        case let .disconnected(reason):
            return formatDisconnect(reason)
        case let .authenticationFailed(message):
            return "authentication failed: \(message)"
        case .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
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
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced:
            return nil
        }
    }

    private func formatCarbonEvent(_ forwarded: ForwardedMessage, isOutgoing: Bool) -> String? {
        let jid = isOutgoing ? forwarded.message.to?.bareJID : forwarded.message.from?.bareJID
        guard let jid, let body = forwarded.message.body else { return nil }
        let timestamp = iso8601(Date())
        let direction = isOutgoing ? "->" : "<-"
        let formatted = if body.hasPrefix("/me ") {
            "* \(jid) \(body.dropFirst(4))"
        } else {
            "\(jid): \(body)"
        }
        return "[\(timestamp)] \(direction) \(formatted) [carbon]"
    }

    private func formatIncomingMessage(_ message: XMPPMessage) -> String? {
        guard let from = message.from?.bareJID, let body = message.body else { return nil }
        let timestamp = iso8601(Date())
        let formatted = if body.hasPrefix("/me ") {
            "* \(from) \(body.dropFirst(4))"
        } else {
            "\(from): \(body)"
        }
        return "[\(timestamp)] <- \(formatted)"
    }

    private func formatMUCEvent(_ event: XMPPEvent) -> String? {
        switch event {
        case let .roomJoined(room, occupancy, isNewlyCreated):
            return formatRoomJoinedMUC(room: room, occupancy: occupancy, isNewlyCreated: isNewlyCreated)
        case let .roomOccupantJoined(room, occupant):
            return "\(room): \(occupant.nickname) joined"
        case let .roomOccupantLeft(room, occupant, reason):
            return formatOccupantLeftMUC(room: room, occupant: occupant, reason: reason)
        case let .roomOccupantNickChanged(room, oldNickname, occupant):
            return "\(room): \(oldNickname) is now known as \(occupant.nickname)"
        case let .roomSubjectChanged(room, subject, setter):
            let who = setter?.bareJID.description ?? "someone"
            let topic = subject ?? "(cleared)"
            return "\(room): topic changed by \(who): \(topic)"
        case let .roomInviteReceived(invite):
            return formatRoomInviteMUC(invite)
        case let .roomMessageReceived(message), let .mucPrivateMessageReceived(message):
            return formatMUCMessage(event, message: message)
        case let .roomDestroyed(room, reason, alternate):
            return formatRoomDestroyedMUC(room: room, reason: reason, alternate: alternate)
        case .mucSelfPingFailed:
            return nil
        case .connected, .streamResumed, .disconnected, .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .messageCarbonReceived, .messageCarbonSent, .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived,
             .chatMarkerReceived, .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced:
            return nil
        }
    }

    private func formatRoomJoinedMUC(room: BareJID, occupancy: RoomOccupancy, isNewlyCreated: Bool) -> String {
        var line = "Joined \(room) as \(occupancy.nickname) (\(occupancy.occupants.count) participants)"
        if isNewlyCreated {
            line += " [new room]"
        }
        if occupancy.flags.contains(.nonAnonymous) {
            line += " [non-anonymous]"
        }
        if occupancy.flags.contains(.logged) {
            line += " [logged]"
        }
        if let subject = occupancy.subject, !subject.isEmpty {
            line += " — topic: \(subject)"
        }
        return line
    }

    private func formatOccupantLeftMUC(room: BareJID, occupant: RoomOccupant, reason: OccupantLeaveReason?) -> String {
        "\(room): \(occupant.nickname) \(occupantLeaveText(reason))"
    }

    private func formatRoomInviteMUC(_ invite: RoomInvite) -> String {
        var line = "Room invite: \(invite.from.bareJID) invites you to \(invite.room)"
        if let reason = invite.reason {
            line += " (\(reason))"
        }
        return line
    }

    private func formatRoomDestroyedMUC(room: BareJID, reason: String?, alternate: BareJID?) -> String {
        var line = "Room \(room) was destroyed"
        if let reason {
            line += " (\(reason))"
        }
        if let alternate {
            line += " → \(alternate)"
        }
        return line
    }

    private func formatMUCMessage(_ event: XMPPEvent, message: XMPPMessage) -> String? {
        if case .mucPrivateMessageReceived = event {
            return formatIncomingPrivateMessage(message)
        }
        return formatIncomingRoomMessage(message)
    }

    private func formatIncomingRoomMessage(_ message: XMPPMessage) -> String? {
        guard let from = message.from, let body = message.body else { return nil }
        let nickname = nicknameFromJID(from)
        let timestamp = iso8601(Date())
        let formatted = if body.hasPrefix("/me ") {
            "* \(nickname) \(body.dropFirst(4))"
        } else {
            "\(from.bareJID)/\(nickname): \(body)"
        }
        return "[\(timestamp)] <- \(formatted)"
    }

    private func formatIncomingPrivateMessage(_ message: XMPPMessage) -> String? {
        guard let from = message.from, let body = message.body else { return nil }
        let nickname = nicknameFromJID(from)
        let timestamp = iso8601(Date())
        let formatted = if body.hasPrefix("/me ") {
            "[PM] * \(nickname) \(body.dropFirst(4))"
        } else {
            "[PM] \(from.bareJID)/\(nickname): \(body)"
        }
        return "[\(timestamp)] <- \(formatted)"
    }

    private func formatJingleEvent(_ event: XMPPEvent) -> String? {
        switch event {
        case let .jingleFileTransferReceived(offer):
            return formatFileOffer(
                fileName: offer.fileName, fileSize: offer.fileSize,
                from: offer.from.bareJID.description, sid: offer.sid
            )
        case let .jingleFileTransferProgress(sid, bytesTransferred, totalBytes):
            let (progress, state) = jingleProgressState(bytesTransferred: bytesTransferred, totalBytes: totalBytes)
            return formatJingleTransferProgress(
                fileName: sid, fileSize: totalBytes, progress: progress, state: state
            )
        case let .jingleFileTransferCompleted(sid):
            return formatJingleTransferCompleted(sid: sid)
        case let .jingleFileTransferFailed(sid, reason):
            return formatJingleTransferFailed(sid: sid, reason: reason)
        case .connected, .streamResumed, .disconnected, .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
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
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced:
            return nil
        }
    }

    private func formatMiscEvent(_ event: XMPPEvent) -> String? {
        switch event {
        case let .presenceSubscriptionRequest(from: jid):
            return "Subscription request from \(jid)"
        case let .deliveryReceiptReceived(messageID, from):
            return "delivery receipt: \(messageID) from \(from.bareJID)"
        case let .messageCorrected(_, newBody, from):
            return "message corrected by \(from.bareJID): \(newBody)"
        case let .messageError(_, from, error):
            return "message error from \(from.bareJID): \(error.displayText)"
        case let .messageRetracted(originalID, from):
            return "[retracted] message retracted by \(from.bareJID) (id: \(originalID))"
        case let .messageModerated(originalID, moderator, room, reason):
            let reasonStr = reason.map { ": \($0)" } ?? ""
            return "[moderated] message moderated by \(moderator) in \(room) (id: \(originalID))\(reasonStr)"
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
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced:
            return nil
        }
    }

    private func formatDisconnect(_ reason: DisconnectReason) -> String {
        switch reason {
        case .requested:
            return "disconnected"
        case let .streamError(condition, text):
            let detail = text ?? condition?.rawValue ?? "unknown"
            return "disconnected: stream error: \(detail)"
        case let .connectionLost(message):
            return "disconnected: connection lost: \(message)"
        case let .redirect(host, port):
            let target = port.map { "\(host):\($0)" } ?? host
            return "redirected to \(target)"
        }
    }

    // MARK: - Room Formatting

    func formatRoom(_ room: DiscoveredRoom) -> String {
        if let name = room.name {
            return "\(name) (\(room.jidString))"
        }
        return room.jidString
    }

    func formatBookmark(_ bookmark: RoomBookmark) -> String {
        var line = bookmark.name ?? bookmark.jidString
        if bookmark.name != nil {
            line += " (\(bookmark.jidString))"
        }
        if bookmark.autojoin {
            line += " [autojoin]"
        }
        if let nick = bookmark.nickname {
            line += " nick: \(nick)"
        }
        return line
    }

    func formatRoomParticipant(_ participant: RoomParticipant) -> String {
        var line = "  \(participant.nickname)"
        if let jid = participant.jidString {
            line += " (\(jid))"
        }
        line += " [\(participant.role.rawValue)]"
        return line
    }

    func formatRoomParticipantGroupHeader(_ group: RoomParticipantGroup) -> String {
        "--- \(group.affiliation.displayName) (\(group.participants.count)) ---"
    }

    func formatRoomJoinedConfirmation(room: String, nickname: String, participantCount: Int, subject: String?) -> String {
        var line = "Joined \(room) as \(nickname) (\(participantCount) participants)"
        if let subject, !subject.isEmpty {
            line += "\nTopic: \(subject)"
        }
        return line
    }

    func formatTransferProgress(fileName: String, fileSize: Int64, progress: Double) -> String {
        let percent = Int(progress * 100)
        return "Uploading \(fileName) (\(formatByteCount(fileSize))): \(percent)%"
    }

    func formatFileMessage(fileName: String, url: String, fileSize: Int64?) -> String {
        var line = "File: \(fileName)"
        if let fileSize {
            line += " (\(formatByteCount(fileSize)))"
        }
        line += "\n  \(url)"
        return line
    }

    func formatFileOffer(fileName: String, fileSize: Int64, from: String, sid: String) -> String {
        "[File offer] \(fileName) (\(formatByteCount(fileSize))) from \(from) (\(sid)) — /accept or /decline"
    }

    func formatJingleTransferProgress(fileName: String, fileSize: Int64, progress: Double, state: String) -> String {
        let percent = Int(progress * 100)
        return "\(fileName) (\(formatByteCount(fileSize))): \(state) \(percent)%"
    }

    func formatJingleTransferCompleted(sid: String) -> String {
        "Transfer completed: \(sid)"
    }

    func formatJingleTransferFailed(sid: String, reason: String) -> String {
        "Transfer failed: \(sid) — \(reason)"
    }

    func formatTypingIndicator(from jid: BareJID, state: ChatState) -> String? {
        state == .composing ? "[\(jid) is typing...]" : nil
    }

    func formatTLSInfo(_ info: TLSInfo) -> String {
        var lines: [String] = []
        lines.append("TLS Version: \(info.protocolVersion)")
        lines.append("Cipher Suite: \(info.cipherSuite)")
        if let subject = info.certificateSubject {
            lines.append("Subject: \(subject)")
        }
        if let issuer = info.certificateIssuer {
            lines.append("Issuer: \(issuer)")
        }
        if let expiry = info.certificateExpiry {
            lines.append("Expires: \(iso8601(expiry))")
        }
        if let fingerprint = info.certificateSHA256 {
            lines.append("SHA-256: \(fingerprint)")
        }
        return lines.joined(separator: "\n")
    }

    func formatServerInfo(_ info: ServerInfo) -> String {
        guard !info.contactAddresses.isEmpty else {
            return "(no server contact information)"
        }
        var lines: [String] = []
        let grouped = Dictionary(grouping: info.contactAddresses, by: \.type)
        for type in ContactAddressType.allCases {
            guard let addresses = grouped[type], !addresses.isEmpty else { continue }
            lines.append("\(type.displayName):")
            for address in addresses {
                lines.append("  \(address.address)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func formatSearchedChannel(_ channel: SearchedChannel) -> String {
        var line = channel.name ?? channel.jidString
        if channel.name != nil {
            line += " (\(channel.jidString))"
        }
        if let userCount = channel.userCount {
            line += " \(userCount) users"
        }
        if let isOpen = channel.isOpen {
            line += isOpen ? " [open]" : " [closed]"
        }
        return line
    }

    func formatProfile(_ profile: ProfileInfo) -> String {
        var lines: [String] = []
        appendProfileNameFields(profile, to: &lines)
        appendProfileDetailFields(profile, to: &lines)
        if lines.isEmpty { return "(no profile data)" }
        return lines.joined(separator: "\n")
    }

    private func appendProfileNameFields(_ profile: ProfileInfo, to lines: inout [String]) {
        if let fullName = profile.fullName { lines.append("Full Name: \(fullName)") }
        if let nickname = profile.nickname { lines.append("Nickname: \(nickname)") }
        if let givenName = profile.givenName { lines.append("Given Name: \(givenName)") }
        if let familyName = profile.familyName { lines.append("Family Name: \(familyName)") }
        if let organization = profile.organization { lines.append("Organization: \(organization)") }
        if let title = profile.title { lines.append("Title: \(title)") }
        if let role = profile.role { lines.append("Role: \(role)") }
    }

    private func appendProfileDetailFields(_ profile: ProfileInfo, to lines: inout [String]) {
        for email in profile.emails where !email.address.isEmpty {
            lines.append("Email: \(email.address)")
        }
        for tel in profile.telephones where !tel.number.isEmpty {
            lines.append("Phone: \(tel.number)")
        }
        if let url = profile.url { lines.append("URL: \(url)") }
        if let birthday = profile.birthday { lines.append("Birthday: \(birthday)") }
        if let note = profile.note { lines.append("Note: \(note)") }
    }
}
