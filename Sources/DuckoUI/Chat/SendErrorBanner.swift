import DuckoCore
import SwiftUI

/// Visible while `windowState.lastSendError` is non-nil. Dismiss clears the
/// error but leaves composer text in place.
struct SendErrorBanner: View {
    @Bindable var windowState: ChatWindowState

    var body: some View {
        if let message = windowState.lastSendError {
            DismissibleBanner(message: message) {
                windowState.clearSendError()
            }
        }
    }
}
