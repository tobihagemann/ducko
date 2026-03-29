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
            .onChange(of: environment.accountService.accounts.isEmpty) { _, isEmpty in
                if !isEmpty, !importInProgress {
                    transitionToContacts()
                }
            }
            .onChange(of: importInProgress) { _, inProgress in
                if !inProgress, !environment.accountService.accounts.isEmpty {
                    transitionToContacts()
                }
            }
    }

    private func transitionToContacts() {
        openWindow(id: "contacts")
        dismissWindow(id: "welcome")
    }
}
