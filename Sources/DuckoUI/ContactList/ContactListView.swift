import DuckoCore
import SwiftUI

struct ContactListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    let searchText: String

    var body: some View {
        List {
            ForEach(filteredGroups) { group in
                Section(group.name) {
                    ForEach(group.contacts) { contact in
                        ContactRowWithMenu(contact: contact)
                            .onTapGesture(count: 2) {
                                openWindow(id: "chat", value: contact.jid.description)
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("contact-list")
    }

    private var filteredGroups: [ContactGroup] {
        let groups = environment.rosterService.groups
        guard !searchText.isEmpty else { return groups }

        return groups.compactMap { group in
            let filtered = group.contacts.filter { contact in
                contact.displayName.localizedStandardContains(searchText)
                    || contact.jid.description.localizedStandardContains(searchText)
            }
            guard !filtered.isEmpty else { return nil }
            return ContactGroup(id: group.id, name: group.name, contacts: filtered)
        }
    }
}

// MARK: - ContactRowWithMenu

private struct ContactRowWithMenu: View {
    let contact: Contact
    @State private var isShowingRenameSheet = false
    @State private var renameText = ""

    var body: some View {
        ContactRow(contact: contact)
            .contextMenu {
                ContactContextMenu(
                    contact: contact,
                    isShowingRenameSheet: $isShowingRenameSheet
                )
            }
            .sheet(isPresented: $isShowingRenameSheet) {
                RenameContactSheet(contact: contact, renameText: $renameText)
            }
    }
}

// MARK: - RenameContactSheet

private struct RenameContactSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let contact: Contact
    @Binding var renameText: String

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Contact")
                .font(.headline)

            TextField("Display name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 250)

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
            }
        }
        .onAppear {
            renameText = contact.localAlias ?? ""
        }
        .padding(20)
        .frame(minWidth: 300)
    }
}
