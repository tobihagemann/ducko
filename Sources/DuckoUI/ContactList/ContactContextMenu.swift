import DuckoCore
import SwiftUI

struct ContactContextMenu: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(TranscriptScope.self) private var transcriptScope
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openChat) private var openChat
    let contact: Contact
    @Binding var isShowingRenameSheet: Bool

    private var conversation: Conversation? {
        environment.chatService.openConversations.first { $0.jid == contact.jid && $0.accountID == contact.accountID }
    }

    var body: some View {
        Button("Start Chat") {
            openChat(contact.jid.description, accountID: contact.accountID)
        }

        Button("Get Info") {
            openWindow(id: "contact-info", value: ContactInfoRef(accountID: contact.accountID, jid: contact.jid.description))
        }
        .accessibilityIdentifier("contact-context-get-info")

        Button("History") {
            let ref = conversation.map { ConversationRef(conversation: $0) }
                ?? ConversationRef(accountID: contact.accountID, jid: contact.jid.description, type: .chat)
            transcriptScope.request(ref)
            openWindow(id: "transcripts")
        }
        .accessibilityIdentifier("contact-context-history")

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

        Button("Send Directed Presence") {
            Task {
                try? await environment.presenceService.sendDirectedPresence(
                    to: contact.jid.description,
                    accountID: contact.accountID
                )
            }
        }
        .accessibilityIdentifier("send-directed-presence-menu-item")

        Divider()

        Button(contact.isBlocked ? "Unblock" : "Block") {
            Task {
                if contact.isBlocked {
                    try? await environment.rosterService.unblockContact(jidString: contact.jid.description, accountID: contact.accountID)
                } else {
                    try? await environment.rosterService.blockContact(jidString: contact.jid.description, accountID: contact.accountID)
                }
            }
        }

        Button("Remove Contact", role: .destructive) {
            Task {
                try? await environment.rosterService.removeContact(contact, accountID: contact.accountID)
            }
        }
    }
}
