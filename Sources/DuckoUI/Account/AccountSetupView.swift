import DuckoCore
import SwiftUI

struct AccountSetupView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var jidString = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Welcome to Ducko")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Enter your XMPP account details to get started.")
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                TextField("JID (e.g. alice@example.com)", text: $jidString)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
            }
            .frame(maxWidth: 300)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Button {
                Task { await connectAccount() }
            } label: {
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Connect")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(jidString.isEmpty || password.isEmpty || isConnecting)
        }
        .padding(40)
        .frame(minWidth: 400, minHeight: 300)
    }

    private func connectAccount() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        do {
            let accountID = try await environment.accountService.createAccount(jidString: jidString)
            do {
                try await environment.accountService.connect(accountID: accountID, password: password)
                await environment.accountService.savePasswordToKeychain(accountID: accountID)
                try await environment.accountService.loadAccounts()
            } catch {
                try? await environment.accountService.deleteAccount(accountID)
                throw error
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
