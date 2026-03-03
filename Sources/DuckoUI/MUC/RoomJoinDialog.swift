import DuckoCore
import SwiftUI

struct RoomJoinDialog: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    var onJoin: (String) -> Void
    @State private var roomJID = ""
    @State private var nickname = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var discoveredRooms: [DiscoveredRoom] = []
    @State private var mucService: String?
    @State private var isBrowsing = false

    private var account: Account? {
        environment.accountService.accounts.first
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Join Room")
                .font(.headline)

            TextField("Room JID (e.g. room@conference.example.com)", text: $roomJID)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 350)
                .accessibilityIdentifier("room-jid-field")

            TextField("Nickname", text: $nickname)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 350)
                .accessibilityIdentifier("room-nickname-field")

            SecureField("Password (optional)", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 350)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Button("Browse Rooms") {
                    browseRooms()
                }
                .disabled(isBrowsing)
                .accessibilityIdentifier("browse-rooms-button")

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Join") {
                    joinRoom()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(roomJID.isEmpty || nickname.isEmpty)
                .accessibilityIdentifier("join-room-button")
            }

            if !discoveredRooms.isEmpty {
                Divider()

                Text("Available Rooms")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                List(discoveredRooms) { room in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(room.name ?? room.jidString)
                                .fontWeight(.medium)
                            if room.name != nil {
                                Text(room.jidString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Button("Join") {
                            roomJID = room.jidString
                            joinRoom()
                        }
                    }
                }
                .listStyle(.plain)
                .frame(height: 150)
            }
        }
        .padding(20)
        .frame(minWidth: 400)
        .task {
            if nickname.isEmpty, let localPart = account?.jid.localPart {
                nickname = localPart
            }
        }
    }

    private func joinRoom() {
        let trimmedJID = roomJID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedJID.isEmpty, !trimmedNick.isEmpty else { return }
        guard trimmedJID.contains("@") else {
            errorMessage = "Invalid room JID: \(trimmedJID)"
            return
        }
        guard let accountID = account?.id else { return }
        errorMessage = nil

        let pw = password.isEmpty ? nil : password
        Task {
            do {
                try await environment.chatService.joinRoom(jidString: trimmedJID, nickname: trimmedNick, password: pw, accountID: accountID)
                onJoin(trimmedJID)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func browseRooms() {
        guard let accountID = account?.id else { return }
        isBrowsing = true
        Task {
            if mucService == nil {
                mucService = await environment.chatService.discoverMUCService(accountID: accountID)
            }
            guard let service = mucService else {
                errorMessage = "No MUC service found on server"
                isBrowsing = false
                return
            }
            do {
                discoveredRooms = try await environment.chatService.discoverRooms(on: service, accountID: accountID)
            } catch {
                errorMessage = error.localizedDescription
            }
            isBrowsing = false
        }
    }
}
