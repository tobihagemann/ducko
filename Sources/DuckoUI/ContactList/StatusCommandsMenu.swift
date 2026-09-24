import DuckoCore
import SwiftUI

/// The menu-bar Status menu, sharing the Contacts header's sections (`StatusMenuSections`) and marks
/// (`StatusSummary`). The ⌘Y item and Custom… follow the status of the account the header shows.
public struct StatusCommandsMenu: View {
    private let environment: AppEnvironment
    private let preferences: StatusBarPreferences
    private let showContacts: () -> Void

    public init(environment: AppEnvironment, preferences: StatusBarPreferences, showContacts: @escaping () -> Void) {
        self.environment = environment
        self.preferences = preferences
        self.showContacts = showContacts
    }

    private var identityAccountID: UUID? {
        environment.identityAccount(preferences: preferences)?.id
    }

    private var currentPresence: (status: PresenceService.PresenceStatus, message: String?) {
        environment.presenceService.displayedPresence(for: identityAccountID)
    }

    private var toggleAction: StatusToggleAction {
        StatusToggleAction.resolve(current: currentPresence.status, savedAwayMessages: preferences.savedMessages(for: .away))
    }

    public var body: some View {
        let presences = environment.presenceService.displayedPresences()
        Group {
            StatusMenuSections {
                ForEach(PresenceService.PresenceStatus.allCases, id: \.self) { status in
                    Button {
                        apply(status)
                    } label: {
                        MenuStatusRow(status: status, label: status.displayName, mark: StatusSummary.mark(for: status, presences: presences))
                    }
                    .keyboardShortcut(status == .available ? KeyboardShortcut("y", modifiers: [.command, .shift]) : nil)
                    .accessibilityIdentifier("status-menu-\(status.rawValue)")
                }
            }

            Divider()

            switch toggleAction {
            case let .customAway(message):
                Button("Custom Away…") {
                    preferences.requestCustomStatus(presence: .away, message: message)
                    showContacts()
                }
                .keyboardShortcut("y")
                .accessibilityIdentifier("status-menu-toggle")
            case .setAvailable:
                Button("Available") {
                    apply(.available)
                }
                .keyboardShortcut("y")
                .accessibilityIdentifier("status-menu-toggle")
            }

            Button("Custom…") {
                preferences.requestCustomStatus(presence: currentPresence.status, message: currentPresence.message ?? "")
                showContacts()
            }
            .accessibilityIdentifier("status-menu-custom")
        }
        .disabled(environment.accountService.accounts.isEmpty)
        // Commands don't inherit the scene's environment, and the shared sections read it.
        .environment(environment)
    }

    private func apply(_ status: PresenceService.PresenceStatus) {
        environment.applyGlobalStatus(status, message: nil)
    }
}
