import DuckoCore
import SwiftUI

struct ContactContextMenu: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    let contact: Contact
    @Binding var isShowingRenameSheet: Bool

    var body: some View {
        Button("Start Chat") {
            openWindow(id: "chat", value: contact.jid.description)
        }

        Divider()

        Button("Rename...") {
            isShowingRenameSheet = true
        }

        Divider()

        Button("Remove Contact", role: .destructive) {
            Task {
                try? await environment.rosterService.removeContact(contact, accountID: contact.accountID)
            }
        }
    }
}
