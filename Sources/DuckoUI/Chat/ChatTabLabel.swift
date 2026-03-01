import DuckoCore
import SwiftUI

struct ChatTabLabel: View {
    let tab: ChatTabManager.Tab
    let isSelected: Bool
    let onClose: () -> Void
    @State private var isHovered = false

    private var displayName: String {
        tab.windowState?.conversation?.displayName ?? tab.jidString
    }

    private var unreadCount: Int {
        tab.windowState?.conversation?.unreadCount ?? 0
    }

    private var isTyping: Bool {
        tab.windowState?.isPartnerTyping ?? false
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(displayName)
                .lineLimit(1)
                .font(.callout)

            if isTyping {
                TypingDotsView()
            }

            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(.caption2)
                    .bold()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.red, in: .capsule)
                    .foregroundStyle(.white)
            }

            if isHovered {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear, in: .rect(cornerRadius: 6))
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("chat-tab-\(tab.jidString)")
    }
}

// MARK: - TypingDotsView

private struct TypingDotsView: View {
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< 3, id: \.self) { _ in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 3, height: 3)
            }
        }
    }
}
