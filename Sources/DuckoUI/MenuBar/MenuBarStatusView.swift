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

        ForEach(statusOptions, id: \.self) { status in
            Button {
                setPresence(status)
            } label: {
                HStack {
                    Text(status.displayName)
                    if status == currentStatus {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }
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

    private var statusOptions: [PresenceService.PresenceStatus] {
        [.available, .away, .dnd, .xa]
    }

    private func setPresence(_ status: PresenceService.PresenceStatus) {
        guard let accountID = environment.accountService.accounts.first(where: { $0.isEnabled })?.id else { return }
        let message = environment.presenceService.myStatusMessage
        Task {
            await environment.presenceService.applyPresence(status, message: message, accountID: accountID) { id in
                try await environment.accountService.connect(accountID: id)
            } disconnect: { id in
                await environment.accountService.disconnect(accountID: id)
            }
        }
    }
}
