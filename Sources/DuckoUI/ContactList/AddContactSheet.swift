import DuckoCore
import SwiftUI

struct AddContactSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var jidString = ""
    @State private var displayName = ""
    @State private var group = ""
    @State private var errorMessage: String?

    private var account: Account? {
        environment.accountService.accounts.first
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Contact")
                .font(.headline)

            TextField("JID (e.g. bob@example.com)", text: $jidString)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .accessibilityIdentifier("add-contact-jid-field")

            TextField("Display name (optional)", text: $displayName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

            TextField("Group (optional)", text: $group)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add Contact") {
                    addContact()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(jidString.isEmpty)
                .accessibilityIdentifier("add-contact-button")
            }
        }
        .padding(20)
        .frame(minWidth: 350)
    }

    private func addContact() {
        let trimmed = jidString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parts = trimmed.split(separator: "@")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            errorMessage = "Invalid JID: \(trimmed)"
            return
        }
        errorMessage = nil

        let name = displayName.isEmpty ? nil : displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = group.isEmpty ? [] : [group.trimmingCharacters(in: .whitespacesAndNewlines)]

        guard let accountID = account?.id else { return }
        Task {
            do {
                try await environment.rosterService.addContact(
                    jidString: trimmed,
                    name: name,
                    groups: groups,
                    accountID: accountID
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
