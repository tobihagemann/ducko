import DuckoCore
import SwiftUI

struct MessageInputView: View {
    let windowState: ChatWindowState
    @State private var text = ""

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            ReplyComposeBar(windowState: windowState)

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 5)
                    .onKeyPress(.return, phases: .down) { keyPress in
                        if keyPress.modifiers.contains(.shift) {
                            return .ignored
                        }
                        sendMessage()
                        return .handled
                    }
                    .onChange(of: text) {
                        guard !text.isEmpty else { return }
                        Task { await windowState.userIsTyping() }
                    }
                    .onChange(of: windowState.editingMessage?.id) {
                        if let editing = windowState.editingMessage {
                            text = editing.body
                        }
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
