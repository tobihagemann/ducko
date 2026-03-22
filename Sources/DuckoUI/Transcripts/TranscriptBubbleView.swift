import DuckoCore
import SwiftUI

/// Read-only message bubble for the transcript viewer.
/// Simplified variant of MessageBubbleView without reply/edit/retract actions.
struct TranscriptBubbleView: View {
    @Environment(ThemeEngine.self) private var theme
    @Environment(\.colorScheme) private var colorScheme
    let message: ChatMessage
    let position: MessagePosition
    let isGroupchat: Bool
    let isSearchResult: Bool

    private var isGroupchatIncoming: Bool {
        isGroupchat && !message.isOutgoing
    }

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

    var body: some View {
        HStack(alignment: .bottom) {
            if message.isOutgoing { Spacer(minLength: 60) }

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
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(message.attachments) { attachment in
                            AttachmentView(attachment: attachment, isOutgoing: message.isOutgoing)
                        }

                        if !message.body.isEmpty {
                            if isActionMessage {
                                Text("* \(message.fromJID) \(actionText)")
                                    .italic()
                            } else if let attributedString = parsedHTMLBody {
                                Text(attributedString)
                            } else {
                                Text(message.body)
                            }
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
                    isVisible: position.isLastInGroup
                )
            }
            .contextMenu {
                Button("Copy Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.body, forType: .string)
                }
            }

            if !message.isOutgoing { Spacer(minLength: 60) }
        }
        .padding(.top, position.isFirstInGroup ? 8 : 2)
        .padding(.horizontal)
        .background(
            isSearchResult ? Color.yellow.opacity(0.15) : Color.clear,
            in: .rect(cornerRadius: 8)
        )
    }
}
