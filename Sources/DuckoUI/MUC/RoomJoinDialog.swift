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

            VStack(alignment: .leading, spacing: 4) {
                TextField("Room address or JID (e.g. room@conference.example.com)", text: $roomJID)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("room-jid-field")

                if !roomJID.contains("@"), let mucService {
                    Text("Service: \(mucService)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 350)

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
            guard let accountID = account?.id else { return }
            mucService = await environment.chatService.discoverMUCService(accountID: accountID)
        }
    }

    private func joinRoom() {
        let trimmedInput = roomJID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty, !trimmedNick.isEmpty else { return }
        errorMessage = nil

        guard let accountID = account?.id else { return }

        let pw = password.isEmpty ? nil : password
        Task {
            do {
                let resolvedJID: String
                if trimmedInput.contains("@") {
                    resolvedJID = trimmedInput
                } else {
                    let normalized = trimmedInput.lowercased().replacingOccurrences(of: " ", with: "-")
                    guard !normalized.contains("/") else {
                        errorMessage = "Room name cannot contain / characters"
                        return
                    }
                    await ensureMUCService(accountID: accountID)
                    guard let service = mucService else {
                        errorMessage = "No MUC service found on server"
                        return
                    }
                    resolvedJID = "\(normalized)@\(service)"
                }
                try await environment.chatService.joinRoom(jidString: resolvedJID, nickname: trimmedNick, password: pw, accountID: accountID)
                onJoin(resolvedJID)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func ensureMUCService(accountID: UUID) async {
        if mucService == nil {
            mucService = await environment.chatService.discoverMUCService(accountID: accountID)
        }
    }

    private func browseRooms() {
        guard let accountID = account?.id else { return }
        isBrowsing = true
        Task {
            await ensureMUCService(accountID: accountID)
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
