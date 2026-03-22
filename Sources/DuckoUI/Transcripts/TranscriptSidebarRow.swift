import DuckoCore
import SwiftUI

struct TranscriptSidebarRow: View {
    let conversation: Conversation

    var body: some View {
        HStack {
            Image(systemName: conversation.type == .groupchat
                ? "bubble.left.and.bubble.right"
                : "bubble.left")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayName ?? conversation.jid.description)
                    .lineLimit(1)

                if conversation.displayName != nil {
                    Text(conversation.jid.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let date = conversation.lastMessageDate {
                Text(date, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
