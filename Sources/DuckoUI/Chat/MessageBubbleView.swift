import DuckoCore
import SwiftUI

struct MessageBubbleView: View {
    @Environment(ThemeEngine.self) private var theme
    let message: ChatMessage
    let position: MessagePosition
    let isHovered: Bool
    let repliedMessage: ChatMessage?
    let windowState: ChatWindowState

    private var isGroupchatIncoming: Bool {
        message.type == "groupchat" && !message.isOutgoing
    }

    private var actionSenderName: String {
        if message.isOutgoing {
            return "You"
        }
        if isGroupchatIncoming {
            return message.fromJID
        }
        return windowState.contact?.displayName ?? message.fromJID
    }

    private var showAvatar: Bool {
        theme.current.showAvatars && !message.isOutgoing && theme.current.avatarPosition == .leading
    }

    @ViewBuilder
    private var avatarView: some View {
        if let contact = windowState.contact, !windowState.isGroupchat {
            AvatarView(contact: contact, size: theme.current.avatarSize)
        } else {
            ParticipantAvatarView(nickname: message.fromJID, size: theme.current.avatarSize)
        }
    }

    var body: some View {
        HStack(alignment: .bottom) {
            if message.isOutgoing { Spacer(minLength: 60) }

            if showAvatar {
                if position.isLastInGroup {
                    avatarView
                } else {
                    Color.clear
                        .frame(width: theme.current.avatarSize, height: theme.current.avatarSize)
                }
            }

            MessageContentView(
                message: message,
                isGroupchatIncoming: isGroupchatIncoming,
                isMetadataVisible: position.isLastInGroup || isHovered,
                actionSenderName: actionSenderName,
                header: {
                    if let replied = repliedMessage {
                        ReplyQuoteView(
                            senderName: replied.isOutgoing ? "You" : replied.fromJID,
                            bodyPreview: replied.body
                        )
                    }
                },
                footer: {
                    if theme.current.showLinkPreviews, let preview = windowState.linkPreview(for: message) {
                        LinkPreviewCard(preview: preview)
                    }
                }
            )
            .contextMenu {
                MessageContextMenu(message: message, windowState: windowState)
            }

            if !message.isOutgoing { Spacer(minLength: 60) }
        }
    }
}
