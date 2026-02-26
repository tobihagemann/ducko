import DuckoCore
import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 60) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                Text(message.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        message.isOutgoing ? Color.accentColor : Color(.separatorColor),
                        in: .rect(cornerRadius: 12)
                    )
                    .foregroundStyle(message.isOutgoing ? .white : .primary)

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !message.isOutgoing { Spacer(minLength: 60) }
        }
    }
}
