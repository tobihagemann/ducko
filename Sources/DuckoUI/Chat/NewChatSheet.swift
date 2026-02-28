import DuckoCore
import SwiftUI

struct NewChatSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedConversationID: UUID?
    @State private var jidString = ""
    @State private var errorMessage: String?

    private var account: Account? {
        environment.accountService.accounts.first
    }

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
                    Task { await startChat() }
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

    private func startChat() async {
        guard let accountID = account?.id else { return }
        errorMessage = nil

        do {
            let conversationID = try await environment.chatService.startConversation(
                jidString: jidString,
                accountID: accountID
            )
            selectedConversationID = conversationID
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
