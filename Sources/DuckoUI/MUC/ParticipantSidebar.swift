import DuckoCore
import Foundation
import SwiftUI

struct ParticipantSidebar: View {
    @Environment(AppEnvironment.self) private var environment
    let roomJIDString: String
    let roomNickname: String?
    let accountID: UUID?

    private var groups: [RoomParticipantGroup] {
        guard let accountID else { return [] }
        return environment.chatService.participantGroups(forRoomJIDString: roomJIDString, accountID: accountID)
    }

    private var myParticipant: RoomParticipant? {
        guard let nickname = roomNickname, let accountID else { return nil }
        let participants = environment.chatService.participants(forRoomJIDString: roomJIDString, accountID: accountID)
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
                            roomJIDString: roomJIDString,
                            accountID: accountID
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
