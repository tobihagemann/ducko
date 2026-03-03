import DuckoCore
import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage
    let position: MessagePosition
    let isHovered: Bool
    let repliedMessage: ChatMessage?
    let windowState: ChatWindowState

    private var isGroupchatIncoming: Bool {
        message.type == "groupchat" && !message.isOutgoing
    }

    private var isImageOnlyMessage: Bool {
        message.body.isEmpty && message.attachments.count == 1 && message.attachments[0].isImage
    }

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 60) }

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
                            Text(message.body)
                        }

                        if let preview = windowState.linkPreview(for: message) {
                            LinkPreviewCard(preview: preview)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        message.isOutgoing ? Color.accentColor : Color(.separatorColor),
                        in: .rect(cornerRadius: 12)
                    )
                    .foregroundStyle(message.isOutgoing ? .white : .primary)
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
