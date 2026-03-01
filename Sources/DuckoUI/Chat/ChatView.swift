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

            MessageListView(messages: windowState.messages)

            Divider()

            MessageInputView(windowState: windowState)
        }
    }
}
