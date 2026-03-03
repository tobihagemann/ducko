import DuckoCore
import SwiftUI

struct RoomCreationDialog: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    var onJoin: (String) -> Void
    @State private var roomName = ""
    @State private var nickname = ""
    @State private var errorMessage: String?
    @State private var mucService: String?

    private var account: Account? {
        environment.accountService.accounts.first
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Create Room")
                .font(.headline)

            TextField("Room name", text: $roomName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .accessibilityIdentifier("room-name-field")

            TextField("Nickname", text: $nickname)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

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

                Button("Create") {
                    createRoom()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(roomName.isEmpty || nickname.isEmpty)
                .accessibilityIdentifier("create-room-button")
            }
        }
        .padding(20)
        .frame(minWidth: 350)
        .task {
            guard let accountID = account?.id else { return }
            if nickname.isEmpty, let localPart = account?.jid.localPart {
                nickname = localPart
            }
            mucService = await environment.chatService.discoverMUCService(accountID: accountID)
        }
    }

    private func createRoom() {
        let trimmedName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let trimmedNick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedNick.isEmpty else { return }
        guard !trimmedName.contains("@"), !trimmedName.contains("/") else {
            errorMessage = "Room name cannot contain @ or / characters"
            return
        }
        guard let service = mucService else {
            errorMessage = "No MUC service found on server"
            return
        }
        guard let accountID = account?.id else { return }
        errorMessage = nil

        let roomJID = "\(trimmedName)@\(service)"
        Task {
            do {
                try await environment.chatService.joinRoom(jidString: roomJID, nickname: trimmedNick, accountID: accountID)
                onJoin(roomJID)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
