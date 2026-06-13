import DuckoCore
import SwiftUI

struct StatusBarView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isShowingCustomStatus = false
    @State private var isHoveringStatus = false

    private var account: Account? {
        environment.accountService.accounts.first { $0.isEnabled }
    }

    /// The enabled account's ID once it has reached `.connected`; `nil` while it
    /// is still connecting. `fetchOwnProfile` no-ops until the client connects,
    /// so keying the fetch on this re-runs it when the handshake completes
    /// instead of leaving the header blank for the rest of the session.
    private var connectedAccountID: UUID? {
        guard let account,
              case .connected? = environment.accountService.connectionStates[account.id]
        else { return nil }
        return account.id
    }

    /// The enabled account's own profile, resolved per-account so switching
    /// accounts never shows the previous account's avatar or nickname.
    private var ownProfile: ProfileInfo? {
        guard let accountID = account?.id else { return nil }
        return environment.profileService.ownProfile(for: accountID)
    }

    var body: some View {
        HStack(spacing: 8) {
            PresenceIndicator(status: environment.presenceService.myPresence)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                statusMenu
            }

            Spacer(minLength: 0)

            AvatarView(imageData: ownProfile?.photoData, name: displayName, size: 40)
                .accessibilityIdentifier("my-avatar")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .task(id: connectedAccountID) {
            guard let accountID = connectedAccountID,
                  environment.profileService.ownProfile(for: accountID) == nil else { return }
            await environment.profileService.fetchOwnProfile(accountID: accountID)
        }
        .sheet(isPresented: $isShowingCustomStatus) {
            CustomStatusSheet(
                presence: customSheetPresence,
                message: environment.presenceService.myStatusMessage ?? ""
            ) { presence, message in
                apply(presence, message: message)
            }
        }
    }

    // MARK: - Status menu

    private var statusMenu: some View {
        Menu {
            // Selecting a base presence clears any custom message.
            Picker("Status", selection: Binding(
                get: { environment.presenceService.myPresence },
                set: { apply($0, message: nil) }
            )) {
                ForEach(PresenceService.PresenceStatus.allCases, id: \.self) { status in
                    Text(status.displayName).tag(status)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Divider()

            Button("Custom…") {
                isShowingCustomStatus = true
            }
        } label: {
            HStack(spacing: 3) {
                Text(statusLabel)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 1)
            .padding(.horizontal, 5)
            // Transparent until hover. The negative horizontal padding below
            // cancels this inner padding for layout so the label stays aligned
            // with the name above, while the hover fill still extends past it.
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isHoveringStatus ? 0.1 : 0))
            )
            .padding(.horizontal, -5)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHoveringStatus = $0 }
        .accessibilityIdentifier("status-picker")
        // The custom `Menu` label doesn't surface its text as `kAXValue`, so
        // publish the current status label explicitly for VoiceOver and the UI
        // tests that read it back after a selection.
        .accessibilityValue(statusLabel)
    }

    // MARK: - Computed

    private var displayName: String {
        account?.displayName
            ?? ownProfile?.nickname
            ?? account?.jid.localPart
            ?? account?.jid.domainPart
            ?? "Me"
    }

    /// The closed-menu label: the custom status message when one is set,
    /// otherwise the current presence name (Adium shows the message in place
    /// of the presence label).
    private var statusLabel: String {
        if let message = environment.presenceService.myStatusMessage, !message.isEmpty {
            return message
        }
        return environment.presenceService.myPresence.displayName
    }

    /// Presence to preselect in the custom-status sheet — the current one,
    /// unless it is offline (which has no custom message).
    private var customSheetPresence: PresenceService.PresenceStatus {
        let current = environment.presenceService.myPresence
        return current == .offline ? .available : current
    }

    // MARK: - Actions

    private func apply(_ status: PresenceService.PresenceStatus, message: String?) {
        guard let accountID = account?.id else { return }
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (trimmed?.isEmpty ?? true) ? nil : trimmed
        Task {
            await environment.presenceService.applyPresence(status, message: resolved, accountID: accountID) { id in
                try await environment.accountService.connect(accountID: id)
            } disconnect: { id in
                await environment.accountService.disconnect(accountID: id)
            }
        }
    }
}

/// Sheet for composing a custom status: pick the presence and type a message,
/// reachable from the "Custom…" item in the status dropdown.
private struct CustomStatusSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var presence: PresenceService.PresenceStatus
    @State var message: String
    let onApply: (PresenceService.PresenceStatus, String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Custom Status")
                .font(.headline)

            Picker("Status", selection: $presence) {
                ForEach(PresenceService.PresenceStatus.selectableCases, id: \.self) { status in
                    Text(status.displayName).tag(status)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 240)

            TextField("Status message", text: $message)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .accessibilityIdentifier("custom-status-message-field")
                .onSubmit { applyAndDismiss() }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Set") {
                    applyAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 300)
    }

    private func applyAndDismiss() {
        onApply(presence, message)
        dismiss()
    }
}
