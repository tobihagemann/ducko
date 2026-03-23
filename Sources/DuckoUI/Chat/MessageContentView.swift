import DuckoCore
import SwiftUI

/// Shared message bubble content used by both MessageBubbleView and TranscriptBubbleView.
/// Renders groupchat sender label, retracted/content bubble, and metadata.
struct MessageContentView<Header: View, Footer: View>: View {
    @Environment(ThemeEngine.self) private var theme
    @Environment(\.colorScheme) private var colorScheme
    let message: ChatMessage
    let isGroupchatIncoming: Bool
    let isMetadataVisible: Bool
    let actionSenderName: String
    @ViewBuilder let header: Header
    @ViewBuilder let footer: Footer

    private var isActionMessage: Bool {
        message.body.hasPrefix("/me ")
    }

    private var actionText: String {
        String(message.body.dropFirst(4))
    }

    private var parsedHTMLBody: AttributedString? {
        guard let html = message.htmlBody else { return nil }
        return HTMLAttributedStringParser.parse(html)
    }

    private var isImageOnlyMessage: Bool {
        message.body.isEmpty && message.attachments.count == 1 && message.attachments[0].isImage
    }

    var body: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
            if isGroupchatIncoming {
                Text(message.fromJID)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.forNickname(message.fromJID, colorScheme: colorScheme))
                    .padding(.leading, 4)
            }

            if message.isRetracted {
                Text("This message was retracted")
                    .italic()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, theme.current.bubblePadding)
                    .padding(.vertical, theme.current.bubblePadding * 0.67)
                    .background(
                        theme.bubbleColor(isOutgoing: message.isOutgoing, colorScheme: colorScheme),
                        in: .rect(cornerRadius: theme.current.bubbleCornerRadius)
                    )
                    .accessibilityIdentifier("retracted-message")
            } else {
                header

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

                        footer
                    }
                    .padding(.horizontal, theme.current.bubblePadding)
                    .padding(.vertical, theme.current.bubblePadding * 0.67)
                    .background(
                        theme.bubbleColor(isOutgoing: message.isOutgoing, colorScheme: colorScheme),
                        in: .rect(cornerRadius: theme.current.bubbleCornerRadius)
                    )
                    .foregroundStyle(theme.textColor(isOutgoing: message.isOutgoing, colorScheme: colorScheme))
                }
            }

            MessageMetadataView(
                message: message,
                isVisible: isMetadataVisible
            )
        }
    }
}

extension MessageContentView where Header == EmptyView, Footer == EmptyView {
    init(
        message: ChatMessage,
        isGroupchatIncoming: Bool,
        isMetadataVisible: Bool,
        actionSenderName: String
    ) {
        self.init(
            message: message,
            isGroupchatIncoming: isGroupchatIncoming,
            isMetadataVisible: isMetadataVisible,
            actionSenderName: actionSenderName,
            header: { EmptyView() },
            footer: { EmptyView() }
        )
    }
}
