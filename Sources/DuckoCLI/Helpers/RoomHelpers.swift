import DuckoCore
import Foundation

func defaultNickname(for account: Account) -> String {
    account.jid.localPart ?? account.jid.description
}

func waitForRoomJoined(roomJID: String, environment: AppEnvironment, timeout: TimeInterval = 15) async throws {
    let deadline = ContinuousClock.now + .seconds(timeout)
    while ContinuousClock.now < deadline {
        let participants = await MainActor.run { environment.chatService.roomParticipants[roomJID] }
        if let participants, !participants.isEmpty {
            return
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw CLIError.roomJoinTimeout(roomJID)
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
