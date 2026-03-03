import DuckoCore
import SwiftUI

struct RoomRow: View {
    @Environment(AppEnvironment.self) private var environment
    let conversation: Conversation

    private var participantCount: Int {
        environment.chatService.participantCount(forRoomJIDString: conversation.jid.description)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayName ?? conversation.jid.localPart ?? conversation.jid.description)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if let subject = conversation.roomSubject, !subject.isEmpty {
                    Text(subject)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if participantCount > 0 {
                    Text("\(participantCount) participants")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    .background(.red, in: .capsule)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("room-row-\(conversation.jid)")
    }
}
