import DuckoCore
import DuckoXMPP
import Foundation

func handleJoinREPLCommand(_ arguments: String, context: REPLContext) async -> RoomSelectionChange {
    guard !arguments.isEmpty else {
        print("Usage: /join <room-jid> [nickname]")
        return .unchanged
    }
    let parts = arguments.split(separator: " ", maxSplits: 1)
    let roomJID = String(parts[0])
    let nick = parts.count > 1 ? String(parts[1]) : context.accountJID.localPart ?? context.accountJID.description
    do {
        try await context.environment.chatService.joinRoomAwaitingEcho(
            jidString: roomJID, nickname: nick,
            accountID: context.accountID, timeout: .seconds(15)
        )
        let count = await MainActor.run { context.environment.chatService.participantCount(forRoomJIDString: roomJID, accountID: context.accountID) }
        print(context.formatter.formatRoomJoinedConfirmation(room: roomJID, nickname: nick, participantCount: count, subject: nil))
        let isNewlyCreated = await MainActor.run { context.environment.chatService.isRoomNewlyCreated(jidString: roomJID, accountID: context.accountID) }
        if isNewlyCreated {
            print("Room created and locked — run /config submit-default to open it, or /config to customize.")
        }
        return .select(roomJID)
    } catch {
        print(context.formatter.formatError(error))
        return .unchanged
    }
}

func handleLeaveREPLCommand(_ arguments: String, context: REPLContext, currentRoom: String?) async -> RoomSelectionChange {
    guard let roomJID = targetRoom(arguments, currentRoom: currentRoom, context: context) else { return .unchanged }
    do {
        try await context.environment.chatService.leaveRoom(jidString: roomJID, accountID: context.accountID)
        print("Left \(roomJID).")
        return currentRoom == roomJID ? .clear : .unchanged
    } catch {
        print(context.formatter.formatError(error))
        return .unchanged
    }
}

func handleMembersREPLCommand(_ arguments: String, context: REPLContext, currentRoom: String?) async {
    guard let roomJID = targetRoom(arguments, currentRoom: currentRoom, context: context) else { return }
    await printRoomMembers(jidString: roomJID, accountID: context.accountID, environment: context.environment, formatter: context.formatter)
}

func handleTopicREPLCommand(_ arguments: String, context: REPLContext, currentRoom: String?) async {
    if arguments.isEmpty {
        // Only a pushed subject is cached; there is no fetch-on-demand API, so confirm the current room instead.
        guard let roomJID = requireCurrentRoom(currentRoom, context: context) else { return }
        print("Current room: \(roomJID)")
        return
    }
    guard let (roomJID, subject) = parseTopicArgs(arguments, currentRoom: currentRoom) else {
        print(context.formatter.formatError(CLIError.noRoomSpecified))
        return
    }
    do {
        try await context.environment.chatService.setRoomSubject(jidString: roomJID, subject: subject, accountID: context.accountID)
        print("Topic set for \(roomJID).")
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleNickREPLCommand(_ arguments: String, context: REPLContext, currentRoom: String?) async {
    guard !arguments.isEmpty else {
        print("Usage: /nick <new-nickname>")
        return
    }
    guard let roomJID = requireCurrentRoom(currentRoom, context: context) else { return }
    do {
        try await context.environment.chatService.changeRoomNickname(jidString: roomJID, newNickname: arguments, accountID: context.accountID)
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleDestroyREPLCommand(_ arguments: String, context: REPLContext, currentRoom: String?) async -> RoomSelectionChange {
    guard let roomJID = requireCurrentRoom(currentRoom, context: context) else { return .unchanged }
    do {
        try await context.environment.chatService.destroyRoom(
            jidString: roomJID,
            reason: arguments.isEmpty ? nil : arguments,
            accountID: context.accountID
        )
        print("Room \(roomJID) destroyed.")
        return .clear
    } catch {
        print(context.formatter.formatError(error))
        return .unchanged
    }
}

func handleVoiceREPLCommand(_ arguments: String, context: REPLContext, currentRoom: String?) async {
    let usage = "Usage: /voice grant|revoke <nickname>"
    let parts = arguments.split(separator: " ", maxSplits: 1)
    guard parts.count == 2 else {
        print(usage)
        return
    }
    let action = String(parts[0])
    let nickname = String(parts[1])
    guard let roomJID = requireCurrentRoom(currentRoom, context: context) else { return }
    do {
        switch action {
        case "grant":
            try await context.environment.chatService.grantVoice(nickname: nickname, inRoomJIDString: roomJID, accountID: context.accountID)
            print("Granted voice to \(nickname).")
        case "revoke":
            try await context.environment.chatService.revokeVoice(nickname: nickname, inRoomJIDString: roomJID, accountID: context.accountID)
            print("Revoked voice from \(nickname).")
        default:
            print(usage)
        }
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleKickREPLCommand(_ arguments: String, context: REPLContext, currentRoom: String?) async {
    guard !arguments.isEmpty else {
        print("Usage: /kick <nickname> [reason]  (quote nicknames with spaces: /kick \"Alice Smith\" reason)")
        return
    }
    guard let roomJID = requireCurrentRoom(currentRoom, context: context) else { return }
    do {
        let parsed = try parseNicknameArgument(arguments)
        try await context.environment.chatService.kickOccupant(
            nickname: parsed.nickname,
            fromRoomJIDString: roomJID,
            reason: parsed.trailingArgument,
            accountID: context.accountID
        )
        print("Kicked \(parsed.nickname) from \(roomJID).")
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleAffiliationsREPLCommand(_ arguments: String, context: REPLContext, currentRoom: String?) async {
    guard let roomJID = requireCurrentRoom(currentRoom, context: context) else { return }
    let affiliation = arguments.isEmpty ? RoomAffiliation.member : RoomAffiliation(rawValue: arguments)
    guard let affiliation, affiliation != RoomAffiliation.none else {
        print("Usage: /affiliations [member|admin|owner|outcast]")
        return
    }
    do {
        let items = try await context.environment.chatService.getAffiliationList(
            affiliation: affiliation,
            inRoomJIDString: roomJID,
            accountID: context.accountID
        )
        if items.isEmpty {
            print("No \(affiliation.displayName.lowercased())s.")
        } else {
            print("--- \(affiliation.displayName)s (\(items.count)) ---")
            for item in items {
                var line = "  \(item.jidString)"
                if let nickname = item.nickname {
                    line += " (\(nickname))"
                }
                print(line)
            }
        }
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleConfigREPLCommand(_ arguments: String, context: REPLContext, currentRoom: String?) async {
    guard let roomJID = requireCurrentRoom(currentRoom, context: context) else { return }
    switch arguments {
    case "":
        do {
            let fields = try await context.environment.chatService.getRoomConfig(jidString: roomJID, accountID: context.accountID)
            let visible = fields.filter(\.isUserEditable)
            if visible.isEmpty {
                print("No configuration fields.")
            } else {
                for field in visible {
                    let label = field.label ?? field.variable
                    let value = field.values.joined(separator: ", ")
                    print("  \(label): \(value)")
                }
            }
        } catch {
            print(context.formatter.formatError(error))
        }
    case "submit-default":
        do {
            try await context.environment.chatService.submitRoomConfig(jidString: roomJID, fields: [], accountID: context.accountID)
            print("Submitted default room configuration for \(roomJID).")
        } catch {
            print(context.formatter.formatError(error))
        }
    default:
        print("Usage: /config [submit-default]")
    }
}

func handleModerateREPLCommand(_ arguments: String, context: REPLContext, currentRoom: String?) async {
    guard let roomJID = requireCurrentRoom(currentRoom, context: context) else { return }
    guard let bareJID = BareJID.parse(roomJID) else {
        print(context.formatter.formatError(CLIError.invalidJID(roomJID)))
        return
    }
    do {
        let messages = try await fetchHistory(
            jid: bareJID, before: nil, limit: 20,
            environment: context.environment, accountID: context.accountID
        )
        guard let target = messages.last(where: { !$0.isRetracted && !$0.isOutgoing && $0.serverID != nil }),
              let serverID = target.serverID
        else {
            print("No moderatable message found.")
            return
        }
        try await context.environment.chatService.moderateMessage(
            serverID: serverID, in: bareJID,
            reason: arguments.isEmpty ? nil : arguments, accountID: context.accountID
        )
        print("Moderated message (server-id: \(serverID)).")
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleRoomsREPLCommand(_ arguments: String, context: REPLContext) async {
    do {
        let serviceJID = try await resolveMUCService(arguments.isEmpty ? nil : arguments, environment: context.environment, accountID: context.accountID)
        let rooms = try await context.environment.chatService.discoverRooms(on: serviceJID, accountID: context.accountID)
        printDiscoveredRooms(rooms, formatter: context.formatter)
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handlePMREPLCommand(_ arguments: String, context: REPLContext, currentRoom: String?) async {
    let usage = "Usage: /pm <nickname> <message>  (quote nicknames with spaces: /pm \"Alice Smith\" hello)"
    guard !arguments.isEmpty else {
        print(usage)
        return
    }
    guard let roomJID = requireCurrentRoom(currentRoom, context: context) else { return }
    do {
        let parsed = try parseNicknameArgument(arguments)
        guard let body = parsed.trailingArgument else {
            print(usage)
            return
        }
        try await context.environment.chatService.sendMUCPrivateMessage(
            roomJIDString: roomJID, nickname: parsed.nickname, body: body, accountID: context.accountID
        )
        print("PM to \(parsed.nickname) sent.")
    } catch {
        print(context.formatter.formatError(error))
    }
}

/// The explicit room argument when given, otherwise the current room; reports when neither exists.
private func targetRoom(_ argument: String, currentRoom: String?, context: REPLContext) -> String? {
    argument.isEmpty ? requireCurrentRoom(currentRoom, context: context) : argument
}

private func requireCurrentRoom(_ currentRoom: String?, context: REPLContext) -> String? {
    if currentRoom == nil {
        print(context.formatter.formatError(CLIError.noRoomSpecified))
    }
    return currentRoom
}
