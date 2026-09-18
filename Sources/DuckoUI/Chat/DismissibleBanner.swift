import SwiftUI

/// Orange warning banner with a message and dismiss button.
struct DismissibleBanner: View {
    let message: String
    var dismissalLabel = "Dismiss error"
    var dismissalShortcut: KeyboardShortcut?
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dismissalLabel)
            .keyboardShortcut(dismissalShortcut)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }
}
