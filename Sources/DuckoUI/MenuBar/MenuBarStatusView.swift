import AppKit
import DuckoCore
import SwiftUI

public struct MenuBarStatusView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow

    private var currentStatus: PresenceService.PresenceStatus {
        environment.presenceService.myPresence
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
        // No identity switcher here, so resolve the empty-`connectOnLaunch` reconnect fallback on the spot.
        let identityAccountID = environment.accountService.firstConnectedAccount?.id
            ?? environment.accountService.accounts.first { $0.isEnabled }?.id
        Task {
            // Picking a base presence clears any custom status message and broadcasts to every online account,
            // matching the Contacts "me" header so both surfaces send the same payload.
            await environment.presenceService.applyGlobalPresence(status, message: nil, identityAccountID: identityAccountID) { id in
                try await environment.accountService.connect(accountID: id)
            } disconnect: { id in
                await environment.accountService.disconnect(accountID: id)
            }
        }
    }
}
