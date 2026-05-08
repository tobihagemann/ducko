import DuckoCore
import SwiftUI

public struct WelcomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var importInProgress = false

    public init() {}

    public var body: some View {
        AccountSetupView(importInProgress: $importInProgress)
            .onChange(of: hasConnectedAccount) { _, isConnected in
                if isConnected, !importInProgress {
                    transitionToContacts()
                }
            }
            .onChange(of: importInProgress) { _, inProgress in
                if !inProgress, !environment.accountService.accounts.isEmpty {
                    transitionToContacts()
                }
            }
    }

    private var hasConnectedAccount: Bool {
        environment.accountService.hasAnyConnectedAccount
    }

    private func transitionToContacts() {
        openWindow(id: "contacts")
        dismissWindow(id: "welcome")
    }
}
