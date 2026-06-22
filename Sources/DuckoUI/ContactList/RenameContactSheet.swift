import DuckoCore
import SwiftUI

/// Sets a local alias for a contact. Presented from the contact's context menu
/// via `ContactListView`'s `.sheet(item:)`.
struct RenameContactSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let contact: Contact
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Contact")
                .font(.headline)

            TextField("Display name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 250)
                .accessibilityIdentifier("rename-contact-field")

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    Task {
                        try? await environment.rosterService.renameContact(
                            contact,
                            newAlias: renameText,
                            accountID: contact.accountID
                        )
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("rename-contact-button")
            }
        }
        .onAppear {
            renameText = contact.localAlias ?? ""
        }
        .padding(20)
        .frame(minWidth: 300)
    }
}
