import DuckoCore
import SwiftUI

struct StatusBarView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(StatusBarPreferences.self) private var preferences
    @State private var isShowingCustomStatus = false
    @State private var isHoveringStatus = false

    /// Caches the last identity that resolved to a connected account, so a freshly-picked identity that is still
    /// `.connecting` holds the previous avatar/name/profile instead of snapping to `firstConnectedAccount`.
    @State private var lastResolvedIdentityID: UUID?

    /// The account whose avatar/name/profile the header shows. Resolution order: the persisted pick if connected
    /// → the last identity that resolved while connected (so a pick still connecting, or accounts finishing their
    /// handshakes in different orders, don't bounce the header) → first connected → first enabled. Display-only:
    /// status always applies globally (not through this account).
    private var identityAccount: Account? {
        let service = environment.accountService
        let accounts = service.accounts
        if let pickedID = preferences.identityAccountID,
           let picked = accounts.first(where: { $0.id == pickedID }),
           case .connected? = service.connectionStates[pickedID] {
            return picked
        }
        if let held = connectedHeldAccount {
            return held
        }
        return service.firstConnectedAccount ?? accounts.first { $0.isEnabled }
    }

    /// The last identity that resolved while connected, if it is still enabled and connected — a pure cache of
    /// the last good resolution that keeps the header stable through connect ordering and a pick's connecting gap.
    private var connectedHeldAccount: Account? {
        guard let id = lastResolvedIdentityID,
              let account = environment.accountService.accounts.first(where: { $0.id == id && $0.isEnabled }),
              case .connected? = environment.accountService.connectionStates[id]
        else { return nil }
        return account
    }

    /// Enabled accounts, offered by the identity switcher (shown only when more than one exists).
    private var enabledAccounts: [Account] {
        environment.accountService.accounts.filter(\.isEnabled)
    }

    /// The identity account's ID once it has reached `.connected`; `nil` while it is still connecting.
    /// `fetchOwnProfile` no-ops until the client connects, so keying the fetch on this re-runs it when the
    /// handshake completes instead of leaving the header blank for the rest of the session.
    private var connectedAccountID: UUID? {
        guard let account = identityAccount,
              case .connected? = environment.accountService.connectionStates[account.id]
        else { return nil }
        return account.id
    }

    /// The identity account's own profile, resolved per-account so switching accounts never shows the previous
    /// account's avatar or nickname.
    private var ownProfile: ProfileInfo? {
        guard let accountID = identityAccount?.id else { return nil }
        return environment.profileService.ownProfile(for: accountID)
    }

    var body: some View {
        HStack(spacing: 8) {
            PresenceIndicator(status: headerPresence.status)

            VStack(alignment: .leading, spacing: 2) {
                identityName

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
            guard let accountID = connectedAccountID else { return }
            lastResolvedIdentityID = accountID
            if environment.profileService.ownProfile(for: accountID) == nil {
                await environment.profileService.fetchOwnProfile(accountID: accountID)
            }
        }
        .sheet(isPresented: $isShowingCustomStatus) {
            CustomStatusSheet(
                presence: customSheetPresence,
                message: headerPresence.message ?? ""
            ) { presence, message, save in
                if save {
                    preferences.saveMessage(message, for: presence)
                }
                applyGlobal(presence, message: message)
            }
        }
    }

    // MARK: - Identity switcher

    @ViewBuilder
    private var identityName: some View {
        if enabledAccounts.count > 1 {
            Menu {
                ForEach(enabledAccounts) { account in
                    Button {
                        preferences.identityAccountID = account.id
                    } label: {
                        HStack {
                            MenuStatusDot(status: displayedStatus(for: account.id))
                            Text(account.displayName ?? account.jid.description)
                        }
                    }
                }
            } label: {
                Text(displayName)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("identity-switcher")
        } else {
            Text(displayName)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
    }

    // MARK: - Status menu

    private var statusMenu: some View {
        Menu {
            ForEach(PresenceService.PresenceStatus.allCases, id: \.self) { status in
                Button {
                    applyGlobal(status, message: nil)
                } label: {
                    MenuStatusRow(
                        status: status,
                        label: status.displayName,
                        isActive: status == environment.presenceService.myPresence && environment.presenceService.myStatusMessage == nil
                    )
                }
            }

            if !preferences.savedMessages.isEmpty {
                Divider()
                savedMessagesSection
            }

            if environment.accountService.connectedAccounts.count > 1 {
                Divider()
                AccountStatusMenu()
            }

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

    private var savedMessagesSection: some View {
        ForEach(PresenceService.PresenceStatus.selectableCases, id: \.self) { status in
            ForEach(preferences.savedMessages(for: status), id: \.self) { message in
                Button {
                    applyGlobal(status, message: message)
                } label: {
                    MenuStatusRow(
                        status: status,
                        label: message,
                        isActive: message == environment.presenceService.myStatusMessage
                    )
                }
            }
        }
    }

    // MARK: - Computed

    private var displayName: String {
        identityAccount?.displayName
            ?? ownProfile?.nickname
            ?? identityAccount?.jid.localPart
            ?? identityAccount?.jid.domainPart
            ?? "Me"
    }

    /// The status the header reflects: the displayed identity account's effective status, so a per-account
    /// override on that account shows through (not the global value). With no override — the common case —
    /// effective equals global, so the header is unchanged.
    private var headerPresence: (status: PresenceService.PresenceStatus, message: String?) {
        guard let id = identityAccount?.id else {
            return (environment.presenceService.myPresence, environment.presenceService.myStatusMessage)
        }
        return environment.presenceService.effectivePresence(for: id)
    }

    /// The closed-menu label: the custom status message when one is set,
    /// otherwise the current presence name (Adium shows the message in place
    /// of the presence label).
    private var statusLabel: String {
        if let message = headerPresence.message, !message.isEmpty {
            return message
        }
        return headerPresence.status.displayName
    }

    /// Presence to preselect in the custom-status sheet — the one the header shows,
    /// unless it is offline (which has no custom message).
    private var customSheetPresence: PresenceService.PresenceStatus {
        let current = headerPresence.status
        return current == .offline ? .available : current
    }

    /// An account's status as shown next to its name: Offline when not connected (so a disconnected account
    /// never displays the leaked global status), otherwise its effective (override-aware) status.
    private func displayedStatus(for accountID: UUID) -> PresenceService.PresenceStatus {
        if case .connected? = environment.accountService.connectionStates[accountID] {
            return environment.presenceService.effectiveStatus(for: accountID)
        }
        return .offline
    }

    // MARK: - Actions

    private func applyGlobal(_ status: PresenceService.PresenceStatus, message: String?) {
        let resolved = normalize(message)
        Task {
            await environment.presenceService.applyGlobalPresence(
                status,
                message: resolved,
                identityAccountID: identityAccount?.id
            ) { id in
                try await environment.accountService.connect(accountID: id)
            } disconnect: { id in
                await environment.accountService.disconnect(accountID: id)
            }
        }
    }

    private func normalize(_ message: String?) -> String? {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}

/// Sheet for composing a custom status: pick the presence and type a message,
/// reachable from the "Custom…" item in the status dropdown.
private struct CustomStatusSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var presence: PresenceService.PresenceStatus
    @State var message: String
    @State private var saveStatus = false
    let onApply: (PresenceService.PresenceStatus, String, Bool) -> Void

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

            Toggle("Save this status", isOn: $saveStatus)
                .frame(width: 240, alignment: .leading)

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
        onApply(presence, message, saveStatus)
        dismiss()
    }
}
