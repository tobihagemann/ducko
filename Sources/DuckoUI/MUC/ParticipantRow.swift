import DuckoCore
import SwiftUI

struct ParticipantRow: View {
    @Environment(AppEnvironment.self) private var environment
    let participant: RoomParticipant
    let myParticipant: RoomParticipant?
    let roomJIDString: String

    private var canKick: Bool {
        guard let me = myParticipant else { return false }
        return me.role == .moderator && participant.nickname != me.nickname
    }

    private var canBan: Bool {
        guard let me = myParticipant else { return false }
        let isAdminOrOwner = me.affiliation == .admin || me.affiliation == .owner
        return isAdminOrOwner && participant.nickname != me.nickname && participant.jidString != nil
    }

    private var accountID: UUID? {
        environment.accountService.accounts.first?.id
    }

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
        .contextMenu {
            if canKick {
                Button("Kick") {
                    Task {
                        guard let accountID else { return }
                        try? await environment.chatService.kickOccupant(
                            nickname: participant.nickname,
                            fromRoomJIDString: roomJIDString,
                            reason: nil,
                            accountID: accountID
                        )
                    }
                }
            }

            if canBan, let jidString = participant.jidString {
                Button("Ban") {
                    Task {
                        guard let accountID else { return }
                        try? await environment.chatService.banUser(
                            jidString: jidString,
                            fromRoomJIDString: roomJIDString,
                            reason: nil,
                            accountID: accountID
                        )
                    }
                }
            }
        }
    }
}
