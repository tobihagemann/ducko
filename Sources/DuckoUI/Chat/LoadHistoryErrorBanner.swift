import SwiftUI

struct LoadHistoryErrorBanner: View {
    @Bindable var windowState: ChatWindowState

    var body: some View {
        if let message = windowState.lastLoadHistoryError {
            DismissibleBanner(message: "Couldn't load older messages: \(message)") {
                windowState.clearLoadHistoryError()
            }
        }
    }
}
