import DuckoCore
import SwiftUI

struct ParticipantSidebar: View {
    @Environment(AppEnvironment.self) private var environment
    let roomJIDString: String
    let roomNickname: String?

    private var groups: [RoomParticipantGroup] {
        environment.chatService.participantGroups(forRoomJIDString: roomJIDString)
    }

    private var myParticipant: RoomParticipant? {
        guard let nickname = roomNickname else { return nil }
        let participants = environment.chatService.roomParticipants[roomJIDString] ?? []
        return participants.first { $0.nickname == nickname }
    }

    var body: some View {
        let me = myParticipant
        List {
            ForEach(groups) { group in
                Section(group.affiliation.displayName) {
                    ForEach(group.participants) { participant in
                        ParticipantRow(
                            participant: participant,
                            myParticipant: me,
                            roomJIDString: roomJIDString
                        )
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: 200)
        .accessibilityIdentifier("participant-sidebar")
    }
}
