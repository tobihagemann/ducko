import DuckoCore
import SwiftUI

/// Banner over `MessageInputView` while `windowState.lastSendError` is non-nil. Dismiss clears the error but leaves composer text in place.
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
