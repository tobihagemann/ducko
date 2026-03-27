import DuckoCore
import SwiftUI

public struct ContentView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var hasLoaded = false

    public init() {}

    public var body: some View {
        Group {
            if hasLoaded, !environment.accountService.accounts.isEmpty {
                ContactListWindow()
            } else {
                Color.clear
            }
        }
        .task {
            try? await environment.accountService.loadAccounts()
            hasLoaded = true
            if environment.accountService.accounts.isEmpty {
                openWindow(id: "welcome")
                dismissWindow(id: "contacts")
            } else {
                await environment.accountService.connectEnabledAccounts()
            }
        }
        .onChange(of: environment.accountService.accounts.isEmpty) { _, isEmpty in
            guard hasLoaded else { return }
            if isEmpty {
                openWindow(id: "welcome")
                dismissWindow(id: "contacts")
            }
        }
    }
}
