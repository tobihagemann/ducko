import DuckoCore
import SwiftUI

struct RoomContextMenu: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    let conversation: Conversation
    @Binding var isShowingInviteSheet: Bool
    @Binding var isShowingSettingsSheet: Bool

    private var myParticipant: RoomParticipant? {
        guard let nickname = conversation.roomNickname else { return nil }
        let participants = environment.chatService.roomParticipants[conversation.jid.description] ?? []
        return participants.first { $0.nickname == nickname }
    }

    private var canManageRoom: Bool {
        myParticipant?.affiliation == .owner
    }

    var body: some View {
        Button("Open Chat") {
            openWindow(id: "chat", value: conversation.jid.description)
        }

        if let accountID = conversation.accountID {
            Divider()

            Button(conversation.isPinned ? "Unpin" : "Pin") {
                Task {
                    try? await environment.chatService.togglePin(
                        conversationID: conversation.id,
                        accountID: accountID
                    )
                }
            }

            Button(conversation.isMuted ? "Unmute" : "Mute") {
                Task {
                    try? await environment.chatService.toggleMute(
                        conversationID: conversation.id,
                        accountID: accountID
                    )
                }
            }

            Divider()

            Button("Invite User...") {
                isShowingInviteSheet = true
            }

            if canManageRoom {
                Divider()

                Button("Room Settings...") {
                    isShowingSettingsSheet = true
                }
                .accessibilityIdentifier("room-settings-menu-item")
            }

            Divider()

            Button("Leave Room", role: .destructive) {
                Task {
                    try? await environment.chatService.leaveRoom(
                        jidString: conversation.jid.description,
                        accountID: accountID
                    )
                }
            }
        }
    }
}
