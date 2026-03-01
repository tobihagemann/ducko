import DuckoCore
import SwiftUI

struct MessageInputView: View {
    let windowState: ChatWindowState
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
                .onChange(of: text) {
                    guard !text.isEmpty else { return }
                    Task { await windowState.userIsTyping() }
                }
                .accessibilityIdentifier("message-field")

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(trimmedText.isEmpty)
            .accessibilityIdentifier("send-button")
        }
        .padding(12)
    }

    private func sendMessage() {
        let body = trimmedText
        guard !body.isEmpty else { return }
        text = ""

        Task {
            await windowState.sendMessage(body)
        }
    }
}
