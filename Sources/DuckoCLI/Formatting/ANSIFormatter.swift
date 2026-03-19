import DuckoCore
import DuckoXMPP
import Foundation

struct ANSIFormatter: CLIFormatter {
    // MARK: - ANSI Codes

    private enum Color {
        static let reset = "\u{001B}[0m"
        static let red = "\u{001B}[31m"
        static let green = "\u{001B}[32m"
        static let yellow = "\u{001B}[33m"
        static let cyan = "\u{001B}[36m"
        static let dim = "\u{001B}[2m"
        static let bold = "\u{001B}[1m"
    }

    // MARK: - CLIFormatter

    func formatMessage(_ message: ChatMessage, accountJID: BareJID? = nil) -> String {
        let timestamp = iso8601(message.timestamp)
        let direction = message.isOutgoing ? "->" : "<-"
        let color = message.isOutgoing ? Color.cyan : Color.green
        let displayJID = message.isOutgoing ? (accountJID?.description ?? message.fromJID) : message.fromJID
        let body = if message.body.hasPrefix("/me ") {
            "* \(displayJID) \(message.body.dropFirst(4))"
        } else {
            "\(message.fromJID): \(styledBody(message.body))"
        }
        var line = "\(Color.dim)[\(timestamp)]\(Color.reset) \(color)\(direction) \(body)\(Color.reset)"
        if message.isEncrypted {
            line += " \(Color.green)\(Color.dim)[encrypted]\(Color.reset)"
        }
        if message.isEdited {
            line += " \(Color.dim)[edited]\(Color.reset)"
        }
        if message.isOutgoing, message.isDelivered {
            line += " \(Color.green)\u{2713}\(Color.reset)"
        }
        if let errorText = message.errorText {
            line += " \(Color.red)[error: \(errorText)]\(Color.reset)"
        }
        for attachment in message.attachments where attachment.url != message.body {
            line += "\n" + formatFileMessage(fileName: attachment.displayFileName, url: attachment.url, fileSize: attachment.fileSize)
        }
        return line
    }

    func formatAccount(_ account: Account) -> String {
        "\(Color.bold)\(account.jid)\(Color.reset) \(Color.dim)(\(account.id))\(Color.reset)"
    }

    func formatContactWithPresence(_ contact: Contact, presence: PresenceService.PresenceStatus?) -> String {
        let isOffline = presence == .offline || presence == nil
        let dot = isOffline ? "○" : "●"
        let color = switch presence {
        case .available:
            Color.green
        case .away, .xa:
            Color.yellow
        case .dnd:
            Color.red
        case .offline, .none:
            Color.dim
        }
        let displayName = contact.localAlias ?? contact.name ?? contact.jid.description
        return "\(color)\(dot)\(Color.reset) \(Color.bold)\(displayName)\(Color.reset) (\(contact.jid)) \(Color.dim)[\(contact.subscription.rawValue)]\(Color.reset)"
    }

    func formatGroupHeader(_ group: ContactGroup) -> String {
        "\(Color.bold)--- \(group.name) (\(group.contacts.count)) ---\(Color.reset)"
    }

    func formatPresence(jid: BareJID, status: String, message: String?) -> String {
        let color: String = switch status {
        case "available", "chat":
            Color.green
        case "dnd":
            Color.red
        default:
            Color.yellow
        }
        if let message {
            return "\(color)\(jid)\(Color.reset) is \(color)\(status)\(Color.reset): \(message)"
        }
        return "\(color)\(jid)\(Color.reset) is \(color)\(status)\(Color.reset)"
    }

    func formatError(_ error: any Error) -> String {
        "\(Color.red)error: \(error.localizedDescription)\(Color.reset)"
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
        case .presenceSubscriptionRequest, .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .deliveryReceiptReceived,
             .messageCorrected, .messageRetracted, .messageModerated, .messageError:
            return formatMiscEvent(event)
        case .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged, .roomSubjectChanged,
             .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived, .roomDestroyed,
             .mucSelfPingFailed:
            return formatMUCEvent(event)
        case .jingleFileTransferReceived, .jingleFileRequestReceived,
             .jingleFileTransferProgress, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleChecksumMismatch:
            return formatJingleEvent(event)
        case .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced:
            return formatOMEMOEvent(event)
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
        }
    }

    private func formatOMEMOEvent(_ event: XMPPEvent) -> String? {
        switch event {
        case let .omemoDeviceListReceived(jid, devices):
            return "\(Color.dim)OMEMO devices for \(jid): \(devices.map(String.init).joined(separator: ", "))\(Color.reset)"
        case let .omemoSessionEstablished(jid, deviceID, _):
            return "\(Color.green)OMEMO session established with \(jid) device \(deviceID)\(Color.reset)"
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
             .blockListLoaded, .contactBlocked, .contactUnblocked:
            return nil
        }
    }

    private func formatConnectionEvent(_ event: XMPPEvent) -> String? {
        switch event {
        case let .connected(jid):
            return "\(Color.green)connected as \(jid)\(Color.reset)"
        case let .streamResumed(jid):
            return "\(Color.green)stream resumed as \(jid)\(Color.reset)"
        case let .disconnected(reason):
            return formatDisconnect(reason)
        case let .authenticationFailed(message):
            return "\(Color.red)authentication failed: \(message)\(Color.reset)"
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
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced:
            return nil
        }
    }

    // MARK: - Room Formatting

    func formatRoom(_ room: DiscoveredRoom) -> String {
        if let name = room.name {
            return "\(Color.bold)\(name)\(Color.reset) (\(room.jidString))"
        }
        return room.jidString
    }

    func formatBookmark(_ bookmark: RoomBookmark) -> String {
        var line = "\(Color.bold)\(bookmark.name ?? bookmark.jidString)\(Color.reset)"
        if bookmark.name != nil {
            line += " (\(bookmark.jidString))"
        }
        if bookmark.autojoin {
            line += " \(Color.green)[autojoin]\(Color.reset)"
        }
        if let nick = bookmark.nickname {
            line += " \(Color.dim)nick: \(nick)\(Color.reset)"
        }
        return line
    }

    func formatRoomParticipant(_ participant: RoomParticipant) -> String {
        var line = "  \(Color.green)\(participant.nickname)\(Color.reset)"
        if let jid = participant.jidString {
            line += " (\(jid))"
        }
        line += " \(Color.dim)[\(participant.role.rawValue)]\(Color.reset)"
        return line
    }

    func formatRoomParticipantGroupHeader(_ group: RoomParticipantGroup) -> String {
        "\(Color.bold)--- \(group.affiliation.displayName) (\(group.participants.count)) ---\(Color.reset)"
    }

    func formatRoomJoinedConfirmation(room: String, nickname: String, participantCount: Int, subject: String?) -> String {
        var line = "\(Color.green)Joined \(Color.bold)\(room)\(Color.reset)\(Color.green) as \(nickname) (\(participantCount) participants)\(Color.reset)"
        if let subject, !subject.isEmpty {
            line += "\n\(Color.dim)Topic: \(subject)\(Color.reset)"
        }
        return line
    }

    private func formatCarbonEvent(_ forwarded: ForwardedMessage, isOutgoing: Bool) -> String? {
        let jid = isOutgoing ? forwarded.message.to?.bareJID : forwarded.message.from?.bareJID
        let oob = forwarded.message.oobData
        let body = forwarded.message.body ?? oob.first?.url
        guard let jid, let body else { return nil }
        let timestamp = iso8601(Date())
        let direction = isOutgoing ? "->" : "<-"
        let color = isOutgoing ? Color.cyan : Color.green
        let formatted = if body.hasPrefix("/me ") {
            "* \(jid) \(body.dropFirst(4))"
        } else {
            "\(jid): \(styledBody(body))"
        }
        var line = "\(Color.dim)[\(timestamp)]\(Color.reset) \(color)\(direction) \(formatted) [carbon]\(Color.reset)"
        for item in oob where item.url != body {
            line += "\n" + formatFileMessage(fileName: oobFileName(item.url), url: item.url, fileSize: nil)
        }
        return line
    }

    private func formatIncomingMessage(_ message: XMPPMessage) -> String? {
        guard let from = message.from?.bareJID else { return nil }
        let oob = message.oobData
        let body = message.body ?? oob.first?.url
        guard let body else { return nil }
        let timestamp = iso8601(Date())
        let formatted = if body.hasPrefix("/me ") {
            "* \(from) \(body.dropFirst(4))"
        } else {
            "\(from): \(styledBody(body))"
        }
        var line = "\(Color.dim)[\(timestamp)]\(Color.reset) \(Color.green)<- \(formatted)\(Color.reset)"
        for item in oob where item.url != body {
            line += "\n" + formatFileMessage(fileName: oobFileName(item.url), url: item.url, fileSize: nil)
        }
        return line
    }

    private func formatMUCEvent(_ event: XMPPEvent) -> String? {
        switch event {
        case let .roomJoined(room, occupancy, isNewlyCreated):
            return formatRoomJoinedMUC(room: room, occupancy: occupancy, isNewlyCreated: isNewlyCreated)
        case let .roomOccupantJoined(room, occupant):
            return "\(Color.yellow)\(room): \(occupant.nickname) joined\(Color.reset)"
        case let .roomOccupantLeft(room, occupant, reason):
            return formatOccupantLeftMUC(room: room, occupant: occupant, reason: reason)
        case let .roomOccupantNickChanged(room, oldNickname, occupant):
            return "\(Color.yellow)\(room): \(oldNickname) is now known as \(occupant.nickname)\(Color.reset)"
        case let .roomSubjectChanged(room, subject, setter):
            let who = setter?.bareJID.description ?? "someone"
            let topic = subject ?? "(cleared)"
            return "\(Color.yellow)\(room): topic changed by \(who): \(topic)\(Color.reset)"
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
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced:
            return nil
        }
    }

    private func formatRoomJoinedMUC(room: BareJID, occupancy: RoomOccupancy, isNewlyCreated: Bool) -> String {
        var line = "\(Color.green)Joined \(Color.bold)\(room)\(Color.reset)\(Color.green) as \(occupancy.nickname) (\(occupancy.occupants.count) participants)\(Color.reset)"
        if isNewlyCreated {
            line += " \(Color.yellow)[new room]\(Color.reset)"
        }
        if occupancy.flags.contains(.nonAnonymous) {
            line += " \(Color.yellow)[non-anonymous]\(Color.reset)"
        }
        if occupancy.flags.contains(.logged) {
            line += " \(Color.yellow)[logged]\(Color.reset)"
        }
        if let subject = occupancy.subject, !subject.isEmpty {
            line += " \(Color.dim)— topic: \(subject)\(Color.reset)"
        }
        return line
    }

    private func formatOccupantLeftMUC(room: BareJID, occupant: RoomOccupant, reason: OccupantLeaveReason?) -> String {
        "\(Color.yellow)\(room): \(occupant.nickname) \(occupantLeaveText(reason))\(Color.reset)"
    }

    private func formatRoomInviteMUC(_ invite: RoomInvite) -> String {
        var line = "\(Color.yellow)Room invite: \(invite.from.bareJID) invites you to \(Color.bold)\(invite.room)\(Color.reset)"
        if let reason = invite.reason {
            line += "\(Color.yellow) (\(reason))\(Color.reset)"
        }
        return line
    }

    private func formatRoomDestroyedMUC(room: BareJID, reason: String?, alternate: BareJID?) -> String {
        var line = "\(Color.red)Room \(room) was destroyed\(Color.reset)"
        if let reason {
            line += " \(Color.dim)(\(reason))\(Color.reset)"
        }
        if let alternate {
            line += " \(Color.dim)→ \(alternate)\(Color.reset)"
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
        guard let from = message.from else { return nil }
        let oob = message.oobData
        let body = message.body ?? oob.first?.url
        guard let body else { return nil }
        let nickname = nicknameFromJID(from)
        let timestamp = iso8601(Date())
        let formatted = if body.hasPrefix("/me ") {
            "* \(nickname) \(body.dropFirst(4))"
        } else {
            "\(from.bareJID)/\(nickname): \(styledBody(body))"
        }
        var line = "\(Color.dim)[\(timestamp)]\(Color.reset) \(Color.green)<- \(formatted)\(Color.reset)"
        for item in oob where item.url != body {
            line += "\n" + formatFileMessage(fileName: oobFileName(item.url), url: item.url, fileSize: nil)
        }
        return line
    }

    private func formatIncomingPrivateMessage(_ message: XMPPMessage) -> String? {
        guard let from = message.from else { return nil }
        let oob = message.oobData
        let body = message.body ?? oob.first?.url
        guard let body else { return nil }
        let nickname = nicknameFromJID(from)
        let timestamp = iso8601(Date())
        let formatted = if body.hasPrefix("/me ") {
            "[PM] * \(nickname) \(body.dropFirst(4))"
        } else {
            "[PM] \(from.bareJID)/\(nickname): \(styledBody(body))"
        }
        var line = "\(Color.dim)[\(timestamp)]\(Color.reset) \(Color.cyan)<- \(formatted)\(Color.reset)"
        for item in oob where item.url != body {
            line += "\n" + formatFileMessage(fileName: oobFileName(item.url), url: item.url, fileSize: nil)
        }
        return line
    }

    private func formatJingleEvent(_ event: XMPPEvent) -> String? {
        switch event {
        case let .jingleFileTransferReceived(offer):
            return formatFileOffer(
                fileName: offer.fileName, fileSize: offer.fileSize,
                from: offer.from.bareJID.description, sid: offer.sid
            )
        case let .jingleFileRequestReceived(request):
            return formatFileRequest(
                fileName: request.fileDescription.name, fileSize: request.fileDescription.size,
                from: request.from.bareJID.description, sid: request.sid
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
        case let .jingleChecksumMismatch(sid, _, _):
            return "\(Color.red)\u{2717} checksum mismatch for file transfer \(sid)\(Color.reset)"
        case .jingleChecksumReceived:
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
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced:
            return nil
        }
    }

    private func formatMiscEvent(_ event: XMPPEvent) -> String? {
        switch event {
        case let .presenceSubscriptionRequest(from: jid):
            return "\(Color.yellow)⚡ Subscription request from \(jid) — use /approve or /deny\(Color.reset)"
        case let .presenceSubscriptionApproved(from: jid):
            return "\(Color.green)✓ Subscription approved by \(jid)\(Color.reset)"
        case let .presenceSubscriptionRevoked(from: jid):
            return "\(Color.yellow)✗ Subscription revoked by \(jid)\(Color.reset)"
        case let .deliveryReceiptReceived(messageID, from):
            return "\(Color.dim)\u{2713} delivery receipt: \(messageID) from \(from.bareJID)\(Color.reset)"
        case let .messageCorrected(_, newBody, from):
            return "\(Color.yellow)message corrected by \(from.bareJID): \(newBody)\(Color.reset)"
        case let .messageError(_, from, error):
            return "\(Color.red)message error from \(from.bareJID): \(error.displayText)\(Color.reset)"
        case let .messageRetracted(originalID, from):
            return "\(Color.dim)\u{2298} message retracted by \(from.bareJID) (id: \(originalID))\(Color.reset)"
        case let .messageModerated(originalID, moderator, room, reason):
            let reasonStr = reason.map { ": \($0)" } ?? ""
            return "\(Color.dim)\u{2298} message moderated by \(moderator) in \(room) (id: \(originalID))\(reasonStr)\(Color.reset)"
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
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced:
            return nil
        }
    }

    private func styledBody(_ body: String) -> String {
        let blocks = MessageStylingParser.parse(body)
        return MessageStylingANSIRenderer.render(blocks)
    }

    private func formatDisconnect(_ reason: DisconnectReason) -> String {
        switch reason {
        case .requested:
            return "\(Color.yellow)disconnected\(Color.reset)"
        case let .streamError(condition, text):
            let detail = text ?? condition?.rawValue ?? "unknown"
            return "\(Color.red)disconnected: stream error: \(detail)\(Color.reset)"
        case let .connectionLost(message):
            return "\(Color.red)disconnected: connection lost: \(message)\(Color.reset)"
        case let .redirect(host, port):
            let target = port.map { "\(host):\($0)" } ?? host
            return "\(Color.yellow)redirected to \(target)\(Color.reset)"
        }
    }

    func formatTransferProgress(fileName: String, fileSize: Int64, progress: Double) -> String {
        "\r\(Color.cyan)\(fileName)\(Color.reset) (\(formatByteCount(fileSize))) \(progressBar(progress)) \(Int(progress * 100))%"
    }

    func formatFileMessage(fileName: String, url: String, fileSize: Int64?) -> String {
        var line = "\(Color.bold)\u{1F4CE} \(fileName)\(Color.reset)"
        if let fileSize {
            line += " (\(formatByteCount(fileSize)))"
        }
        line += "\n  \(Color.cyan)\(url)\(Color.reset)"
        return line
    }

    func formatFileOffer(fileName: String, fileSize: Int64, from: String, sid: String) -> String {
        "\(Color.yellow)\u{1F4E5} [File offer] \(fileName) (\(formatByteCount(fileSize))) from \(from) (\(sid)) \u{2014} /accept or /decline\(Color.reset)"
    }

    func formatFileRequest(fileName: String, fileSize: Int64, from: String, sid: String) -> String {
        "\(Color.yellow)\u{1F4E4} [File request] \(from) requests \(fileName) (\(formatByteCount(fileSize))) (\(sid)) \u{2014} /fulfill or /decline\(Color.reset)"
    }

    func formatJingleTransferProgress(fileName: String, fileSize: Int64, progress: Double, state: String) -> String {
        "\r\(Color.cyan)\(fileName)\(Color.reset) (\(formatByteCount(fileSize))) \(progressBar(progress)) \(state) \(Int(progress * 100))%"
    }

    func formatJingleTransferCompleted(sid: String) -> String {
        "\(Color.green)\u{2705} Transfer completed: \(sid)\(Color.reset)"
    }

    func formatJingleTransferFailed(sid: String, reason: String) -> String {
        "\(Color.red)Transfer failed: \(sid) \u{2014} \(reason)\(Color.reset)"
    }

    private func progressBar(_ progress: Double) -> String {
        let barWidth = 20
        let filled = Int(progress * Double(barWidth))
        let empty = barWidth - filled
        let bar = String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: empty)
        return "\(Color.green)\(bar)\(Color.reset)"
    }

    func formatTypingIndicator(from jid: BareJID, state: ChatState) -> String? {
        state == .composing ? "\(Color.dim)[\(jid) is typing...]\(Color.reset)" : nil
    }

    func formatTLSInfo(_ info: TLSInfo) -> String {
        var lines: [String] = []
        lines.append("\(Color.bold)TLS Version:\(Color.reset) \(info.protocolVersion)")
        lines.append("\(Color.bold)Cipher Suite:\(Color.reset) \(info.cipherSuite)")
        if let subject = info.certificateSubject {
            lines.append("\(Color.bold)Subject:\(Color.reset) \(subject)")
        }
        if let issuer = info.certificateIssuer {
            lines.append("\(Color.bold)Issuer:\(Color.reset) \(issuer)")
        }
        if let expiry = info.certificateExpiry {
            lines.append("\(Color.bold)Expires:\(Color.reset) \(iso8601(expiry))")
        }
        if let fingerprint = info.certificateSHA256 {
            lines.append("\(Color.bold)SHA-256:\(Color.reset) \(fingerprint)")
        }
        return lines.joined(separator: "\n")
    }

    func formatServerInfo(_ info: ServerInfo) -> String {
        guard !info.contactAddresses.isEmpty else {
            return "\(Color.dim)(no server contact information)\(Color.reset)"
        }
        var lines: [String] = []
        let grouped = Dictionary(grouping: info.contactAddresses, by: \.type)
        for type in ContactAddressType.allCases {
            guard let addresses = grouped[type], !addresses.isEmpty else { continue }
            lines.append("\(Color.bold)\(type.displayName):\(Color.reset)")
            for address in addresses {
                lines.append("  \(Color.cyan)\(address.address)\(Color.reset)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func formatSearchedChannel(_ channel: SearchedChannel) -> String {
        var line = "\(Color.bold)\(channel.name ?? channel.jidString)\(Color.reset)"
        if channel.name != nil {
            line += " (\(channel.jidString))"
        }
        if let userCount = channel.userCount {
            line += " \(Color.dim)\(userCount) users\(Color.reset)"
        }
        if let isOpen = channel.isOpen {
            let badge = isOpen ? "\(Color.green)[open]\(Color.reset)" : "\(Color.red)[closed]\(Color.reset)"
            line += " \(badge)"
        }
        return line
    }

    func formatProfile(_ profile: ProfileInfo) -> String {
        var lines: [String] = []
        appendProfileNameFields(profile, to: &lines)
        appendProfileDetailFields(profile, to: &lines)
        if lines.isEmpty {
            return "\(Color.dim)(no profile data)\(Color.reset)"
        }
        return lines.joined(separator: "\n")
    }

    private func appendProfileNameFields(_ profile: ProfileInfo, to lines: inout [String]) {
        if let fullName = profile.fullName {
            lines.append("\(Color.bold)Full Name:\(Color.reset) \(fullName)")
        }
        if let nickname = profile.nickname {
            lines.append("\(Color.bold)Nickname:\(Color.reset) \(nickname)")
        }
        if let givenName = profile.givenName {
            lines.append("\(Color.bold)Given Name:\(Color.reset) \(givenName)")
        }
        if let familyName = profile.familyName {
            lines.append("\(Color.bold)Family Name:\(Color.reset) \(familyName)")
        }
        if let organization = profile.organization {
            lines.append("\(Color.bold)Organization:\(Color.reset) \(organization)")
        }
        if let title = profile.title {
            lines.append("\(Color.bold)Title:\(Color.reset) \(title)")
        }
        if let role = profile.role {
            lines.append("\(Color.bold)Role:\(Color.reset) \(role)")
        }
    }

    private func appendProfileDetailFields(_ profile: ProfileInfo, to lines: inout [String]) {
        for email in profile.emails where !email.address.isEmpty {
            lines.append("\(Color.bold)Email:\(Color.reset) \(email.address)")
        }
        for tel in profile.telephones where !tel.number.isEmpty {
            lines.append("\(Color.bold)Phone:\(Color.reset) \(tel.number)")
        }
        if let url = profile.url {
            lines.append("\(Color.bold)URL:\(Color.reset) \(Color.cyan)\(url)\(Color.reset)")
        }
        if let birthday = profile.birthday {
            lines.append("\(Color.bold)Birthday:\(Color.reset) \(birthday)")
        }
        if let note = profile.note {
            lines.append("\(Color.bold)Note:\(Color.reset) \(note)")
        }
    }
}
