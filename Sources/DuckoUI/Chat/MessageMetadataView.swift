import DuckoCore
import SwiftUI

struct MessageMetadataView: View {
    @Environment(ThemeEngine.self) private var theme
    let message: ChatMessage
    let isVisible: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(message.timestamp, style: .time)
                .font(theme.current.timestampFont.resolved)
                .foregroundStyle(.secondary)

            if message.isOutgoing, message.isDelivered {
                Image(systemName: "checkmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if message.isEdited {
                Text("(edited)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if message.errorText != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isVisible)
    }
}
