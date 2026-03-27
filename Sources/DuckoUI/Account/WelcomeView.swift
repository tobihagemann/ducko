import DuckoCore
import SwiftUI

public struct WelcomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    public init() {}

    public var body: some View {
        AccountSetupView()
            .onChange(of: environment.accountService.accounts.isEmpty) { _, isEmpty in
                if !isEmpty {
                    openWindow(id: "contacts")
                    dismissWindow(id: "welcome")
                }
            }
    }
}
