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

            // Manual `Binding(get:set:)` — the setter only fires on user
            // selection, so direct mutations of `myPresence` (e.g. by the
            // idle monitor) do not trigger an extra broadcast through this
            // view. The getter still reflects external mutations so the
            // visible label and AX `kAXValueAttribute` follow the model.
            Picker("Presence", selection: Binding(
                get: { environment.presenceService.myPresence },
                set: { newStatus in setPresence(newStatus) }
            )) {
                ForEach(statusOptions, id: \.self) { status in
                    Text(status.displayName).tag(status)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
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
