import SwiftUI

struct NewChatSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onStartChat: (String) -> Void
    @State private var jidString = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("New Chat")
                .font(.headline)

            TextField("JID (e.g. bob@example.com)", text: $jidString)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .accessibilityIdentifier("new-chat-jid-field")

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Start Chat") {
                    startChat()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(jidString.isEmpty)
                .accessibilityIdentifier("start-chat-button")
            }
        }
        .padding(20)
        .frame(minWidth: 350)
    }

    private func startChat() {
        let trimmed = jidString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.contains("@") else {
            errorMessage = "Invalid JID: \(trimmed)"
            return
        }
        errorMessage = nil
        onStartChat(trimmed)
        dismiss()
    }
}
