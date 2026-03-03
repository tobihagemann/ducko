import DuckoCore
import SwiftUI

struct StatusBarView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var statusMessage = ""

    private var account: Account? {
        environment.accountService.accounts.first { $0.isEnabled }
    }

    var body: some View {
        HStack(spacing: 8) {
            PresenceIndicator(status: environment.presenceService.myPresence)

            Menu {
                ForEach(statusOptions, id: \.self) { status in
                    Button(status.displayName) {
                        setPresence(status)
                    }
                }
            } label: {
                Text(environment.presenceService.myPresence.displayName)
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("status-picker")

            TextField("Status message", text: $statusMessage)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("status-message-field")
                .onSubmit {
                    setPresence(environment.presenceService.myPresence)
                }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear {
            statusMessage = environment.presenceService.myStatusMessage ?? ""
        }
    }

    private var statusOptions: [PresenceService.PresenceStatus] {
        [.available, .away, .dnd, .xa, .offline]
    }

    private func setPresence(_ status: PresenceService.PresenceStatus) {
        guard let accountID = account?.id else { return }
        let message = statusMessage.isEmpty ? nil : statusMessage
        Task {
            await environment.presenceService.applyPresence(status, message: message, accountID: accountID) { id in
                try await environment.accountService.connect(accountID: id)
            } disconnect: { id in
                await environment.accountService.disconnect(accountID: id)
            }
        }
    }
}
