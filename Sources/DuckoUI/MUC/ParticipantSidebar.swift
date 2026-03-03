import DuckoCore
import SwiftUI

struct ParticipantSidebar: View {
    @Environment(AppEnvironment.self) private var environment
    let roomJIDString: String

    private var groups: [RoomParticipantGroup] {
        environment.chatService.participantGroups(forRoomJIDString: roomJIDString)
    }

    var body: some View {
        List {
            ForEach(groups) { group in
                Section(group.affiliation.displayName) {
                    ForEach(group.participants) { participant in
                        ParticipantRow(participant: participant)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: 200)
        .accessibilityIdentifier("participant-sidebar")
    }
}
