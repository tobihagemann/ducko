import DuckoCore
import SwiftUI

struct ContactContextMenu: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    let contact: Contact
    @Binding var isShowingRenameSheet: Bool

    private var conversation: Conversation? {
        environment.chatService.openConversations.first { $0.jid == contact.jid }
    }

    var body: some View {
        Button("Start Chat") {
            openWindow(id: "chat", value: contact.jid.description)
        }

        Divider()

        if let conversation {
            Button(conversation.isPinned ? "Unpin" : "Pin") {
                Task {
                    try? await environment.chatService.togglePin(
                        conversationID: conversation.id,
                        accountID: contact.accountID
                    )
                }
            }

            Button(conversation.isMuted ? "Unmute" : "Mute") {
                Task {
                    try? await environment.chatService.toggleMute(
                        conversationID: conversation.id,
                        accountID: contact.accountID
                    )
                }
            }

            Divider()
        }

        Button("Rename...") {
            isShowingRenameSheet = true
        }

        Divider()

        Button("Remove Contact", role: .destructive) {
            Task {
                try? await environment.rosterService.removeContact(contact, accountID: contact.accountID)
            }
        }
    }
}
