import DuckoCore
import SwiftUI

struct RoomRow: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ThemeEngine.self) private var theme
    @Environment(\.colorScheme) private var colorScheme
    let conversation: Conversation

    /// One lookup feeds both the ring and the caption, so a row cannot say it is joined in one place and not the other.
    private var participantCount: Int {
        RoomCaption.participantCount(for: conversation, chatService: environment.chatService)
    }

    private var caption: RoomCaption {
        RoomCaption.resolve(roomSubject: conversation.roomSubject, participantCount: participantCount)
    }

    private var display: ContactPresenceDisplay {
        ContactPresenceDisplay.resolve(isJoined: participantCount > 0)
    }

    var body: some View {
        HStack(spacing: 8) {
            if theme.current.showPresenceIndicators {
                PresenceIndicator(display: display)
            }

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

            // Rooms have no avatar, so the icon takes the avatar's place and keeps both kinds of row aligned.
            if theme.current.showAvatars {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: theme.current.avatarSize * 0.45))
                    .foregroundStyle(.secondary)
                    .frame(width: theme.current.avatarSize, height: theme.current.avatarSize)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("room-row-\(conversation.jid)")
    }
}
