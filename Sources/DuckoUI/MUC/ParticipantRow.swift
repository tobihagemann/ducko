import DuckoCore
import SwiftUI

struct ParticipantRow: View {
    let participant: RoomParticipant

    var body: some View {
        HStack(spacing: 8) {
            ParticipantAvatarView(nickname: participant.nickname)

            Text(participant.nickname)
                .lineLimit(1)

            Spacer()

            if participant.role == .moderator {
                Text("Mod")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
            }
        }
        .padding(.vertical, 2)
    }
}
