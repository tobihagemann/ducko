import DuckoCore
import Foundation

func defaultNickname(for account: Account) -> String {
    account.jid.localPart ?? account.jid.description
}

func printRoomMembers(jidString: String, environment: AppEnvironment, formatter: any CLIFormatter) async {
    let groups = await MainActor.run { environment.chatService.participantGroups(forRoomJIDString: jidString) }

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
