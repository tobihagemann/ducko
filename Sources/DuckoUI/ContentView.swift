import DuckoCore
import SwiftUI

public struct ContentView: View {
    @Environment(AppEnvironment.self) private var environment

    public init() {}

    public var body: some View {
        Group {
            if environment.accountService.accounts.isEmpty {
                AccountSetupView()
            } else {
                MainChatView()
            }
        }
        .task {
            try? await environment.accountService.loadAccounts()
        }
    }
}
