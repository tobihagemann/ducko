import DuckoCore
import SwiftUI

/// The per-account override section: one submenu per connected account listing the selectable statuses, with a
/// checkmark on each account's effective status. Pins a single account without touching the global status.
/// Shared by the Contacts header and the menu-bar status menus; callers gate it on `connectedAccounts.count > 1`.
struct AccountStatusMenu: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ForEach(environment.accountService.connectedAccounts) { account in
            let displayed = environment.presenceService.effectiveStatus(for: account.id)
            Menu {
                ForEach(PresenceService.PresenceStatus.selectableCases, id: \.self) { status in
                    Button {
                        apply(status, accountID: account.id)
                    } label: {
                        MenuStatusRow(status: status, label: status.displayName, isActive: status == displayed)
                    }
                }
            } label: {
                MenuStatusRow(status: displayed, label: account.displayName ?? account.jid.description, isActive: false)
            }
        }
    }

    private func apply(_ status: PresenceService.PresenceStatus, accountID: UUID) {
        Task {
            await environment.presenceService.applyAccountPresence(status, message: nil, accountID: accountID) { id in
                try await environment.accountService.connect(accountID: id)
            } disconnect: { id in
                await environment.accountService.disconnect(accountID: id)
            }
        }
    }
}
