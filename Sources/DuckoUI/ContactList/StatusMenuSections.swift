import DuckoCore
import SwiftUI

/// A status menu's body: the caller's global rows alone with fewer than two enabled accounts, otherwise those rows
/// under "All Accounts" and a submenu per account under "Each Account".
struct StatusMenuSections<Rows: View>: View {
    @Environment(AppEnvironment.self) private var environment
    @ViewBuilder let rows: Rows

    var body: some View {
        if environment.accountService.enabledAccounts.count > 1 {
            Section("All Accounts") {
                rows
            }
            Section("Each Account") {
                AccountStatusMenu()
            }
        } else {
            rows
        }
    }
}

/// A row per status that applies it to every enabled account.
struct GlobalStatusRows: View {
    @Environment(AppEnvironment.self) private var environment
    let presences: StatusSummary.Presences

    var body: some View {
        ForEach(PresenceService.PresenceStatus.allCases, id: \.self) { status in
            Button {
                environment.applyGlobalStatus(status, message: nil)
            } label: {
                MenuStatusRow(status: status, label: status.displayName, mark: StatusSummary.mark(for: status, presences: presences))
            }
        }
    }
}

/// One submenu per enabled account, checking its displayed status (Offline until it connects). A pick pins or
/// disconnects just that account, leaving the global status alone.
private struct AccountStatusMenu: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ForEach(environment.accountService.enabledAccounts) { account in
            let displayed = environment.presenceService.displayedPresence(for: account.id).status
            Menu {
                ForEach(PresenceService.PresenceStatus.allCases, id: \.self) { status in
                    Button {
                        environment.applyAccountStatus(status, accountID: account.id)
                    } label: {
                        MenuStatusRow(status: status, label: status.displayName, mark: status == displayed ? .checked : .none)
                    }
                }
            } label: {
                MenuStatusRow(status: displayed, label: account.displayName ?? account.jid.description, mark: .none)
            }
        }
    }
}
