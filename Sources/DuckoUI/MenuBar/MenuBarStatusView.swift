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

    private var currentStatus: PresenceService.PresenceStatus {
        environment.presenceService.displayedPresence(for: identityAccountID).status
    }

    public init() {}

    public var body: some View {
        Text(currentStatus.displayName)
            .font(.callout)
            .foregroundStyle(.secondary)

        Divider()

        ForEach(PresenceService.PresenceStatus.selectableCases, id: \.self) { status in
            Button {
                setPresence(status)
            } label: {
                MenuStatusRow(status: status, label: status.displayName, isActive: status == currentStatus)
            }
        }

        if environment.accountService.connectedAccounts.count > 1 {
            Divider()
            AccountStatusMenu()
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

    private func setPresence(_ status: PresenceService.PresenceStatus) {
        // Picking a base presence clears any custom status message and broadcasts to every online account.
        environment.applyGlobalStatus(status, message: nil, identityAccountID: identityAccountID)
    }
}
