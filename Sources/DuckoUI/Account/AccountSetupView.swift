import AppKit
import DuckoCore
import SwiftUI

struct AccountSetupView: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var importInProgress: Bool
    @State private var mode: SetupMode = .importAdium
    @State private var jidString = ""
    @State private var password = ""
    @State private var serverDomain = ""
    @State private var username = ""
    @State private var email = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    private enum SetupMode: String, CaseIterable {
        case importAdium = "Import"
        case login = "Login"
        case register = "Register"
    }

    var body: some View {
        VStack(spacing: 20) {
            if let iconImage = NSApplication.shared.applicationIconImage {
                Image(nsImage: iconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 128, height: 128)
            }

            Text("Welcome to Ducko")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text(subtitleText)
                .foregroundStyle(.secondary)

            Picker("Mode", selection: $mode) {
                ForEach(SetupMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(importInProgress)
            .frame(maxWidth: 300)
            .accessibilityIdentifier("setup-mode-picker")

            VStack(spacing: 12) {
                switch mode {
                case .importAdium:
                    AdiumOnboardingImportView(importInProgress: $importInProgress)
                case .login:
                    loginFields
                case .register:
                    registerFields
                }
            }
            .frame(maxWidth: 300)

            if mode != .importAdium {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                }

                Button {
                    Task {
                        switch mode {
                        case .login:
                            await connectAccount()
                        case .register:
                            await registerAccount()
                        case .importAdium:
                            break
                        }
                    }
                } label: {
                    if isConnecting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(mode == .login ? "Connect" : "Register")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isActionDisabled)
                .accessibilityIdentifier(mode == .login ? "connect-button" : "register-button")
            }
        }
        .padding(40)
        .frame(minWidth: 400, minHeight: 300)
    }

    // MARK: - Fields

    private var loginFields: some View {
        Group {
            TextField("JID (e.g. alice@example.com)", text: $jidString)
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)
                .accessibilityIdentifier("jid-field")

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .accessibilityIdentifier("password-field")
        }
    }

    private var registerFields: some View {
        Group {
            TextField("Server (e.g. example.com)", text: $serverDomain)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("register-server-field")

            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)
                .accessibilityIdentifier("register-username-field")

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.newPassword)
                .accessibilityIdentifier("register-password-field")

            TextField("Email (optional)", text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.emailAddress)
                .accessibilityIdentifier("register-email-field")
        }
    }

    // MARK: - Computed

    private var subtitleText: String {
        switch mode {
        case .importAdium:
            "Import your accounts and chat history from Adium."
        case .login, .register:
            "Enter your XMPP account details to get started."
        }
    }

    private var isActionDisabled: Bool {
        if isConnecting { return true }
        switch mode {
        case .importAdium:
            return true
        case .login:
            return jidString.isEmpty || password.isEmpty
        case .register:
            return serverDomain.isEmpty || username.isEmpty || password.isEmpty
        }
    }

    // MARK: - Actions

    private func connectAccount() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        do {
            _ = try await environment.accountService.createAndConnect(jidString: jidString, password: password)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func registerAccount() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        do {
            _ = try await environment.accountService.registerAccount(
                domain: serverDomain,
                username: username,
                password: password,
                email: email.isEmpty ? nil : email
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
