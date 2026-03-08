import SwiftUI

struct AppearancePreferencesView: View {
    @Environment(ThemeEngine.self) private var themeEngine
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section("Theme") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 12) {
                    ForEach(themeEngine.availableThemes) { theme in
                        ThemeCard(theme: theme, isSelected: themeEngine.current.id == theme.id) {
                            themeEngine.selectTheme(theme)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Preview") {
                themePreview
            }
        }
        .formStyle(.grouped)
    }

    private var themePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                previewBubble(
                    text: "Hello! How are you?",
                    isOutgoing: false
                )
                Spacer()
            }
            HStack {
                Spacer()
                previewBubble(
                    text: "I'm doing great, thanks!",
                    isOutgoing: true
                )
            }
        }
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(.background)
                .shadow(radius: 1)
        }
    }

    private func previewBubble(text: String, isOutgoing: Bool) -> some View {
        Text(text)
            .font(themeEngine.current.messageFont.resolved)
            .padding(.horizontal, themeEngine.current.bubblePadding)
            .padding(.vertical, themeEngine.current.bubblePadding * 0.67)
            .foregroundStyle(themeEngine.textColor(isOutgoing: isOutgoing, colorScheme: colorScheme))
            .background(
                themeEngine.bubbleColor(isOutgoing: isOutgoing, colorScheme: colorScheme),
                in: RoundedRectangle(cornerRadius: themeEngine.current.bubbleCornerRadius)
            )
    }
}

// MARK: - Theme Card

private struct ThemeCard: View {
    let theme: DuckoTheme
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.accentColor.resolved(for: colorScheme))
                    .frame(height: 40)
                    .overlay {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(theme.outgoingBubbleColor.resolved(for: colorScheme))
                                .frame(width: 14, height: 14)
                            Circle()
                                .fill(theme.incomingBubbleColor.resolved(for: colorScheme))
                                .frame(width: 14, height: 14)
                        }
                    }

                Text(theme.name)
                    .font(.caption)
                    .lineLimit(1)

                Text("by \(theme.author)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Theme: \(theme.name)")
    }
}
