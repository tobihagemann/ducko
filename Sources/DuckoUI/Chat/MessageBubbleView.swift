import DuckoCore
import SwiftUI

struct MessageBubbleView: View {
    @Environment(ThemeEngine.self) private var theme
    @Environment(\.colorScheme) private var colorScheme
    let message: ChatMessage
    let position: MessagePosition
    let isHovered: Bool
    let repliedMessage: ChatMessage?
    let windowState: ChatWindowState

    private var isGroupchatIncoming: Bool {
        message.type == "groupchat" && !message.isOutgoing
    }

    private var isActionMessage: Bool {
        message.body.hasPrefix("/me ")
    }

    private var actionText: String {
        String(message.body.dropFirst(4))
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

    private var isImageOnlyMessage: Bool {
        message.body.isEmpty && message.attachments.count == 1 && message.attachments[0].isImage
    }

    private var parsedHTMLBody: AttributedString? {
        guard let html = message.htmlBody else { return nil }
        return HTMLAttributedStringParser.parse(html)
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

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                if isGroupchatIncoming {
                    Text(message.fromJID)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.forNickname(message.fromJID))
                        .padding(.leading, 4)
                }

                if let replied = repliedMessage {
                    ReplyQuoteView(
                        senderName: replied.isOutgoing ? "You" : replied.fromJID,
                        bodyPreview: replied.body
                    )
                }

                if isImageOnlyMessage {
                    AttachmentView(attachment: message.attachments[0], isOutgoing: message.isOutgoing)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(message.attachments) { attachment in
                            AttachmentView(attachment: attachment, isOutgoing: message.isOutgoing)
                        }

                        if !message.body.isEmpty {
                            if isActionMessage {
                                Text("* \(actionSenderName) \(actionText)")
                                    .italic()
                            } else if let attributedString = parsedHTMLBody {
                                Text(attributedString)
                            } else {
                                Text(message.body)
                            }
                        }

                        if theme.current.showLinkPreviews, let preview = windowState.linkPreview(for: message) {
                            LinkPreviewCard(preview: preview)
                        }
                    }
                    .padding(.horizontal, theme.current.bubblePadding)
                    .padding(.vertical, theme.current.bubblePadding * 0.67)
                    .background(
                        theme.bubbleColor(isOutgoing: message.isOutgoing, colorScheme: colorScheme),
                        in: .rect(cornerRadius: theme.current.bubbleCornerRadius)
                    )
                    .foregroundStyle(theme.textColor(isOutgoing: message.isOutgoing, colorScheme: colorScheme))
                }

                MessageMetadataView(
                    message: message,
                    isVisible: position.isLastInGroup || isHovered
                )
            }
            .contextMenu {
                MessageContextMenu(message: message, windowState: windowState)
            }

            if !message.isOutgoing { Spacer(minLength: 60) }
        }
    }
}
