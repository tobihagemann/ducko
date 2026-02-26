import DuckoCore
import SwiftUI

struct ConversationListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var selectedConversationID: UUID?

    var body: some View {
        List(environment.chatService.openConversations, selection: $selectedConversationID) { conversation in
            ConversationRow(conversation: conversation)
        }
        .listStyle(.sidebar)
    }
}

// MARK: - ConversationRow

private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(conversation.displayName ?? conversation.jid.description)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer()

                if let date = conversation.lastMessageDate {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                if let preview = conversation.lastMessagePreview {
                    Text(preview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if conversation.unreadCount > 0 {
                    Text("\(conversation.unreadCount)")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue, in: Capsule())
                }
            }
        }
        .padding(.vertical, 2)
    }
}
