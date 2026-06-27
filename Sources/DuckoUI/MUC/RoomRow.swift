import DuckoCore
import SwiftUI

struct RoomRow: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ThemeEngine.self) private var theme
    @Environment(\.colorScheme) private var colorScheme
    let conversation: Conversation

    private var caption: RoomCaption {
        RoomCaption.resolve(for: conversation, chatService: environment.chatService)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayTitle)
                    .fontWeight(.medium)
                    .lineLimit(1)

                switch caption {
                case let .subject(subject):
                    Text(subject)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                case let .participants(count):
                    Text("\(count) participants")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                case .none:
                    EmptyView()
                }
            }

            Spacer()

            if conversation.unreadCount > 0 {
                Text("\(conversation.unreadCount)")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.current.unreadBadgeColor.resolved(for: colorScheme), in: .capsule)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("room-row-\(conversation.jid)")
    }
}
