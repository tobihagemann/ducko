import DuckoCore
import SwiftUI

struct MessageInputView: View {
    @Environment(AppEnvironment.self) private var environment
    let conversation: Conversation
    @State private var text = ""

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 5)
                .onSubmit { sendMessage() }

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(trimmedText.isEmpty)
        }
        .padding(12)
    }

    private func sendMessage() {
        let body = trimmedText
        guard !body.isEmpty else { return }
        text = ""

        Task {
            try? await environment.chatService.sendMessage(
                to: conversation.jid,
                body: body,
                accountID: conversation.accountID
            )
        }
    }
}
