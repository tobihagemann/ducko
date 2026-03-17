import DuckoCore
import SwiftUI

struct RoomInviteBanner: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ThemeEngine.self) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let invites = environment.chatService.pendingInvites
        if !invites.isEmpty {
            VStack(spacing: 4) {
                ForEach(invites) { invite in
                    RoomInviteRow(invite: invite)
                }
            }
            .padding(.vertical, 4)
            .background(theme.current.accentColor.resolved(for: colorScheme).opacity(0.1))
            .accessibilityIdentifier("room-invite-banner")
        }
    }
}

// MARK: - RoomInviteRow

private struct RoomInviteRow: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    let invite: PendingRoomInvite
    @State private var nickname = ""
    @State private var errorMessage: String?

    private var account: Account? {
        environment.accountService.accounts.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Room invitation: \(invite.roomJIDString)")
                        .font(.callout)
                        .lineLimit(1)

                    if let from = invite.fromJIDString {
                        Text("From: \(from)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let reason = invite.reason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer()
            }

            HStack {
                TextField("Nickname", text: $nickname)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 150)

                Spacer()

                Button("Accept") {
                    accept()
                }
                .tint(.green)
                .disabled(nickname.isEmpty)

                Button("Decline") {
                    decline()
                }
                .tint(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .task {
            if nickname.isEmpty, let localPart = account?.jid.localPart {
                nickname = localPart
            }
        }
    }

    private func accept() {
        let nick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nick.isEmpty, let accountID = account?.id else { return }
        Task {
            do {
                try await environment.chatService.acceptInvite(invite, nickname: nick, accountID: accountID)
                openWindow(id: "chat", value: invite.roomJIDString)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func decline() {
        guard let accountID = account?.id else { return }
        Task {
            do {
                try await environment.chatService.declineInvite(invite, accountID: accountID)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
