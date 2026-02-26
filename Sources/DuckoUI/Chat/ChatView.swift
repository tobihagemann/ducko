import DuckoCore
import SwiftUI

struct ChatView: View {
    @Environment(AppEnvironment.self) private var environment
    let conversation: Conversation

    var body: some View {
        VStack(spacing: 0) {
            ChatHeaderView(conversation: conversation)

            Divider()

            MessageListView()

            Divider()

            MessageInputView(conversation: conversation)
        }
    }
}
