import DuckoCore
import SwiftUI

/// Transient banner shown above `MessageInputView` when a send threw a
/// `ChatService.ChatServiceError`. Visible while `windowState.lastSendError`
/// is non-nil; dismiss button clears the banner via `clearSendError()`,
/// leaving the composer text in place for editing or resend.
struct SendErrorBanner: View {
    @Bindable var windowState: ChatWindowState

    var body: some View {
        if let error = windowState.lastSendError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error.localizedDescription)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    windowState.clearSendError()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss error")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.1))
        }
    }
}
