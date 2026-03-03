import DuckoCore
import SwiftUI

struct RoomContextMenu: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    let conversation: Conversation
    @Binding var isShowingInviteSheet: Bool

    var body: some View {
        Button("Open Chat") {
            openWindow(id: "chat", value: conversation.jid.description)
        }

        Divider()

        Button(conversation.isPinned ? "Unpin" : "Pin") {
            Task {
                try? await environment.chatService.togglePin(
                    conversationID: conversation.id,
                    accountID: conversation.accountID
                )
            }
        }

        Button(conversation.isMuted ? "Unmute" : "Mute") {
            Task {
                try? await environment.chatService.toggleMute(
                    conversationID: conversation.id,
                    accountID: conversation.accountID
                )
            }
        }

        Divider()

        Button("Invite User...") {
            isShowingInviteSheet = true
        }

        Divider()

        Button("Leave Room", role: .destructive) {
            Task {
                try? await environment.chatService.leaveRoom(
                    jidString: conversation.jid.description,
                    accountID: conversation.accountID
                )
            }
        }
    }
}
