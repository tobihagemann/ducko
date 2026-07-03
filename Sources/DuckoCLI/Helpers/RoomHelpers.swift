import DuckoCore
import Foundation

func defaultNickname(for account: Account) -> String {
    account.jid.localPart ?? account.jid.description
}

/// Splits a non-empty `/topic` argument into the room to target and the subject text.
/// A leading `localpart@domain` token (a bare JID addressing a user or room) selects
/// that room explicitly; anything else — including a bare word like "Live" — is subject
/// text for `currentRoom`. Returns `nil` when there's no room to target.
func parseTopicArgs(_ args: String, currentRoom: String?) -> (roomJID: String, subject: String)? {
    let parts = args.split(separator: " ", maxSplits: 1)
    if parts.count > 1, JIDValidation.isValidUserOrRoomJID(String(parts[0])) {
        return (roomJID: String(parts[0]), subject: String(parts[1]))
    }
    guard let currentRoom else { return nil }
    return (roomJID: currentRoom, subject: args)
}

func printRoomMembers(jidString: String, accountID: UUID, environment: AppEnvironment, formatter: any CLIFormatter) async {
    let groups = await MainActor.run { environment.chatService.participantGroups(forRoomJIDString: jidString, accountID: accountID) }

    guard !groups.isEmpty else {
        print("No participants in room.")
        return
    }

    for group in groups {
        print(formatter.formatRoomParticipantGroupHeader(group))
        for participant in group.participants {
            print(formatter.formatRoomParticipant(participant))
        }
    }
}

func printDiscoveredRooms(_ rooms: [DiscoveredRoom], formatter: any CLIFormatter) {
    guard !rooms.isEmpty else {
        print("No rooms found.")
        return
    }

    for room in rooms {
        print(formatter.formatRoom(room))
    }
}
