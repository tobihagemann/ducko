import AppKit
import DuckoCore
import SwiftUI

struct AdiumOnboardingImportView: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var importInProgress: Bool
    @Binding var cachedAccounts: [AdiumAccount]?
    @Binding var cachedLogSources: [AdiumServiceAccount]?
    @Binding var cachedKeychainPasswords: [String: String]?

    @State private var step: ImportStep = .loading
    @State private var accounts: [AdiumAccount] = []
    @State private var logSources: [AdiumServiceAccount] = []
    @State private var selectedAccountIDs: Set<String> = []
    @State private var passwords: [String: String] = [:]
    @State private var keychainPasswords: [String: String] = [:]
    @State private var progress: AdiumImportService.ImportProgress?
    @State private var accountResults: [AccountResult] = []
    @State private var importResult: AdiumImportService.ImportProgress?
    @State private var logImportSkipped = false

    private enum ImportStep {
        case loading
        case accountSetup
        case importing
        case complete
    }

    private typealias AccountResult = AdiumImportCompletionView.AccountResult

    var body: some View {
        VStack(spacing: 12) {
            switch step {
            case .loading:
                loadingView
            case .accountSetup:
                accountSetupView
            case .importing:
                importingView
            case .complete:
                completionView
            }
        }
        .frame(maxWidth: 300)
        .task {
            await discover()
        }
    }

    // MARK: - Subviews

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Looking for Adium data...")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    private var accountSetupView: some View {
        VStack(spacing: 12) {
            if accounts.isEmpty, logSources.isEmpty {
                noDataView
            } else {
                if !accounts.isEmpty {
                    accountListView
                }

                let totalFiles = logSources.reduce(0) { $0 + $1.fileCount }
                if totalFiles > 0 {
                    Text("\(logSources.count) account(s), \(totalFiles) log file(s) to import")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await performImport() }
                } label: {
                    Text("Import from Adium")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasImportableData)
                .accessibilityIdentifier("import-button")
            }
        }
    }

    private var noDataView: some View {
        VStack(spacing: 12) {
            Text("No Adium installation found.")
                .foregroundStyle(.secondary)

            Button("Choose Adium Folder...") {
                browseForAdiumFolder()
            }
            .accessibilityIdentifier("choose-adium-folder-button")

            Text("You can also switch to Login or Register above.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var accountListView: some View {
        VStack(spacing: 8) {
            ForEach(accounts) { account in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(
                        get: { selectedAccountIDs.contains(account.id) },
                        set: { selected in
                            if selected {
                                selectedAccountIDs.insert(account.id)
                            } else {
                                selectedAccountIDs.remove(account.id)
                            }
                        }
                    )) {
                        Text(account.uid)
                            .font(.body)
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("account-toggle-\(account.id)")

                    if selectedAccountIDs.contains(account.id) {
                        if keychainPasswords[account.id] != nil {
                            Label("Password from Keychain", systemImage: "key.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            SecureField("Password", text: Binding(
                                get: { passwords[account.id, default: ""] },
                                set: { passwords[account.id] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.password)
                            .accessibilityIdentifier("account-password-\(account.id)")
                        }

                        if let server = account.connectServer {
                            Text("Server: \(server)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private var importingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)

            if !accountResults.isEmpty {
                let succeeded = accountResults.filter(\.success).count
                Text("\(succeeded)/\(accountResults.count) accounts connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let progress {
                AdiumImportProgressView(progress: progress)
            }
        }
    }

    private var completionView: some View {
        VStack(spacing: 12) {
            AdiumImportCompletionView(result: importResult, accountResults: accountResults)

            if logImportSkipped {
                Text("Log import was skipped because no accounts could connect. You can import logs separately from the app menu.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button("Done") {
                importInProgress = false
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("import-done-button")
        }
    }

    // MARK: - Computed

    private var selectedAccountsWithPasswords: [AdiumAccount] {
        accounts.filter { account in
            selectedAccountIDs.contains(account.id) && !(passwords[account.id]?.isEmpty ?? true)
        }
    }

    private var hasImportableData: Bool {
        if !selectedAccountIDs.isEmpty {
            return selectedAccountIDs.allSatisfy { id in
                !(passwords[id]?.isEmpty ?? true)
            }
        }
        return !logSources.isEmpty
    }

    // MARK: - Actions

    private func discover() async {
        if let cached = cachedAccounts {
            accounts = cached
            logSources = cachedLogSources ?? []
            keychainPasswords = cachedKeychainPasswords ?? [:]
            for (id, pw) in keychainPasswords {
                passwords[id] = pw
            }
            selectedAccountIDs = Set(keychainPasswords.keys)
        } else {
            discoverAt(AdiumAccountDiscovery.defaultUserURL)
        }
        step = .accountSetup
    }

    private func browseForAdiumFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = AdiumAccountDiscovery.defaultUserURL
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        discoverAt(url)
    }

    private func discoverAt(_ userDirectoryURL: URL) {
        accounts = AdiumAccountDiscovery.discoverAccounts(at: userDirectoryURL)

        keychainPasswords = [:]
        for account in accounts {
            if let pw = AdiumKeychainReader.password(for: account) {
                keychainPasswords[account.id] = pw
                passwords[account.id] = pw
            }
        }
        selectedAccountIDs = Set(keychainPasswords.keys)

        let logsURL = userDirectoryURL.appendingPathComponent("Logs")
        do {
            logSources = try AdiumLogDiscovery.discoverSources(at: logsURL)
        } catch {
            logSources = []
        }

        cachedAccounts = accounts
        cachedLogSources = logSources
        cachedKeychainPasswords = keychainPasswords
    }

    private func performImport() async {
        importInProgress = true
        step = .importing

        // Phase 1: Create and connect accounts
        for account in selectedAccountsWithPasswords {
            let password = passwords[account.id] ?? ""
            do {
                _ = try await environment.accountService.createAndConnect(
                    jidString: account.uid,
                    password: password,
                    host: account.connectServer,
                    port: account.connectServer != nil ? (account.connectPort ?? 5222) : nil,
                    resource: account.resource,
                    requireTLS: true,
                    connectOnLaunch: account.autoConnect,
                    importedFrom: "Adium"
                )
                accountResults.append(AccountResult(id: account.id, jid: account.uid, success: true, error: nil))
            } catch {
                accountResults.append(AccountResult(id: account.id, jid: account.uid, success: false, error: error.localizedDescription))
            }
        }

        // Phase 2: Import logs (gated on account connection success when accounts were selected)
        let accountsWereSelected = !selectedAccountIDs.isEmpty
        let anyAccountSucceeded = accountResults.contains(where: \.success)
        let shouldImportLogs = !logSources.isEmpty && (!accountsWereSelected || anyAccountSucceeded)

        if shouldImportLogs {
            let importService = AdiumImportService(store: environment.store, transcripts: environment.transcripts)
            do {
                importResult = try await importService.importLogs(from: logSources) { p in
                    Task { @MainActor in
                        progress = p
                    }
                }
            } catch {
                importResult = .failure(error: error)
            }
        } else if accountsWereSelected, !logSources.isEmpty {
            logImportSkipped = true
        }

        step = .complete
    }
}
