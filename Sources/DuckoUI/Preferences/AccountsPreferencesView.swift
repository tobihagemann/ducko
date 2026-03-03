import DuckoCore
import SwiftUI

struct AccountsPreferencesView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selectedAccountID: UUID?
    @State private var editingAccount: Account?
    @State private var isShowingAddSheet = false

    private var accounts: [Account] {
        environment.accountService.accounts
    }

    var body: some View {
        HSplitView {
            accountList
                .frame(minWidth: 180, maxWidth: 220)

            accountDetail
                .frame(maxWidth: .infinity)
        }
        .task {
            try? await environment.accountService.loadAccounts()
        }
        .sheet(item: $editingAccount) { account in
            AccountEditSheet(account: account)
        }
        .sheet(isPresented: $isShowingAddSheet) {
            AccountAddSheet()
        }
    }

    // MARK: - Account List

    private var accountList: some View {
        VStack(spacing: 0) {
            List(accounts, selection: $selectedAccountID) { account in
                HStack {
                    connectionIndicator(for: account.id)
                    Text(account.displayName ?? account.jid.description)
                        .lineLimit(1)
                }
            }

            Divider()

            HStack(spacing: 0) {
                Button {
                    isShowingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add Account")

                Button {
                    guard let id = selectedAccountID else { return }
                    Task {
                        try? await environment.accountService.deleteAccount(id)
                        selectedAccountID = nil
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedAccountID == nil)
                .accessibilityLabel("Remove Account")

                Spacer()
            }
            .padding(6)
        }
    }

    // MARK: - Account Detail

    @ViewBuilder
    private var accountDetail: some View {
        if let account = accounts.first(where: { $0.id == selectedAccountID }) {
            AccountDetailView(
                account: account,
                onEdit: { editingAccount = account }
            )
        } else {
            Text("Select an account")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Helpers

    private func connectionIndicator(for accountID: UUID) -> some View {
        let state = environment.accountService.connectionStates[accountID]
        let color: Color = switch state {
        case .connected:
            .green
        case .connecting:
            .yellow
        case .error:
            .red
        case .disconnected, .none:
            .gray
        }
        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(stateLabel(state))
    }

    private func stateLabel(_ state: AccountService.ConnectionState?) -> String {
        switch state {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .error: "Error"
        case .disconnected, .none: "Disconnected"
        }
    }
}

// MARK: - Account Detail View

private struct AccountDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    let account: Account
    let onEdit: () -> Void

    private var connectionState: AccountService.ConnectionState? {
        environment.accountService.connectionStates[account.id]
    }

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("JID", value: account.jid.description)

                if let displayName = account.displayName {
                    LabeledContent("Display Name", value: displayName)
                }

                if let host = account.host {
                    LabeledContent("Host", value: host)
                }

                if let port = account.port {
                    LabeledContent("Port", value: "\(port)")
                }

                if let resource = account.resource {
                    LabeledContent("Resource", value: resource)
                }
            }

            Section("Status") {
                LabeledContent("Enabled", value: account.isEnabled ? "Yes" : "No")
                LabeledContent("Connect on Launch", value: account.connectOnLaunch ? "Yes" : "No")
                LabeledContent("Connection", value: connectionLabel)
            }

            Section {
                HStack {
                    Button("Edit...") {
                        onEdit()
                    }

                    Spacer()

                    connectionButton
                }
            }
        }
        .formStyle(.grouped)
    }

    private var connectionLabel: String {
        switch connectionState {
        case .connected: "Connected"
        case .connecting: "Connecting..."
        case let .error(message): "Error: \(message)"
        case .disconnected, .none: "Disconnected"
        }
    }

    @ViewBuilder
    private var connectionButton: some View {
        switch connectionState {
        case .connected, .connecting:
            Button("Disconnect") {
                Task {
                    await environment.accountService.disconnect(accountID: account.id)
                }
            }
        case .disconnected, .error, .none:
            Button("Connect") {
                Task {
                    try? await environment.accountService.connect(accountID: account.id)
                }
            }
        }
    }
}

// MARK: - Account Edit Sheet

private struct AccountEditSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String
    @State private var host: String
    @State private var portString: String
    @State private var resource: String
    @State private var connectOnLaunch: Bool
    @State private var isEnabled: Bool

    private let accountID: UUID

    init(account: Account) {
        self.accountID = account.id
        _displayName = State(initialValue: account.displayName ?? "")
        _host = State(initialValue: account.host ?? "")
        _portString = State(initialValue: account.port.map(String.init) ?? "")
        _resource = State(initialValue: account.resource ?? "")
        _connectOnLaunch = State(initialValue: account.connectOnLaunch)
        _isEnabled = State(initialValue: account.isEnabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Display Name", text: $displayName)
                TextField("Host (optional)", text: $host)
                TextField("Port (optional)", text: $portString)
                TextField("Resource (optional)", text: $resource)
                Toggle("Connect on Launch", isOn: $connectOnLaunch)
                Toggle("Enabled", isOn: $isEnabled)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 400)
    }

    private func save() {
        guard var account = environment.accountService.accounts.first(where: { $0.id == accountID }) else { return }
        account.displayName = displayName.isEmpty ? nil : displayName
        account.host = host.isEmpty ? nil : host
        account.port = Int(portString)
        account.resource = resource.isEmpty ? nil : resource
        account.connectOnLaunch = connectOnLaunch
        account.isEnabled = isEnabled
        Task {
            try? await environment.accountService.updateAccount(account)
            dismiss()
        }
    }
}

// MARK: - Account Add Sheet

private struct AccountAddSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var jid = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isAdding = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("JID (e.g. alice@example.com)", text: $jid)
                    .textContentType(.username)
                SecureField("Password", text: $password)

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    addAccount()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(jid.isEmpty || password.isEmpty || isAdding)
            }
            .padding()
        }
        .frame(width: 400)
    }

    private func addAccount() {
        errorMessage = nil
        isAdding = true
        Task {
            do {
                let accountID = try await environment.accountService.createAccount(jidString: jid)
                do {
                    try await environment.accountService.connect(accountID: accountID, password: password)
                } catch {
                    try? await environment.accountService.deleteAccount(accountID)
                    throw error
                }
                await environment.accountService.savePassword(accountID: accountID)
                await environment.accountService.disconnect(accountID: accountID)
                try await environment.accountService.loadAccounts()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isAdding = false
            }
        }
    }
}
