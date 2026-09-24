import AppKit
import DuckoCore
import SwiftUI

public struct MenuBarStatusView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(StatusBarPreferences.self) private var preferences
    @Environment(\.openWindow) private var openWindow

    private var identityAccountID: UUID? {
        environment.identityAccount(preferences: preferences)?.id
    }

    public init() {}

    public var body: some View {
        let presences = environment.presenceService.displayedPresences()

        Text(StatusSummary.label(for: environment.presenceService.displayedPresence(for: identityAccountID), presences: presences))
            .font(.callout)
            .foregroundStyle(.secondary)

        Divider()

        StatusMenuSections {
            GlobalStatusRows(presences: presences)
        }

        Divider()

        Button("Show Contact List") {
            openWindow(id: "contacts")
        }

        Divider()

        Button("Quit Ducko") {
            NSApplication.shared.terminate(nil)
        }
    }
}
