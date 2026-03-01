import DuckoCore
import SwiftUI

struct ChatView: View {
    @Environment(AppEnvironment.self) private var environment
    let windowState: ChatWindowState

    var body: some View {
        VStack(spacing: 0) {
            if let conversation = windowState.conversation {
                ChatHeaderView(conversation: conversation)

                Divider()
            }

            if windowState.isSearching {
                MessageSearchBar(windowState: windowState)

                Divider()
            }

            MessageListView(windowState: windowState)

            if windowState.isPartnerTyping {
                TypingIndicatorView()
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Divider()

            MessageInputView(windowState: windowState)
        }
        .animation(.easeInOut(duration: 0.2), value: windowState.isPartnerTyping)
    }
}
