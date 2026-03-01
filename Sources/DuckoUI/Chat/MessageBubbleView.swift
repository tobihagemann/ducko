import DuckoCore
import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage
    let position: MessagePosition
    let isHovered: Bool
    let repliedMessage: ChatMessage?
    let windowState: ChatWindowState

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 60) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                if let replied = repliedMessage {
                    ReplyQuoteView(
                        senderName: replied.isOutgoing ? "You" : replied.fromJID,
                        bodyPreview: replied.body
                    )
                }

                Text(message.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        message.isOutgoing ? Color.accentColor : Color(.separatorColor),
                        in: .rect(cornerRadius: 12)
                    )
                    .foregroundStyle(message.isOutgoing ? .white : .primary)

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
