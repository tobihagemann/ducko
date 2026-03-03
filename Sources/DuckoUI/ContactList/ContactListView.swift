import DuckoCore
import SwiftUI

private let roomsSectionKey = "__rooms__"

struct ContactListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    let searchText: String
    let preferences: ContactListPreferences

    private var roomConversations: [Conversation] {
        environment.chatService.openConversations.filter { $0.type == .groupchat }
    }

    var body: some View {
        List {
            ForEach(sortedAndFilteredGroups) { group in
                let expanded = Binding(
                    get: { preferences.isGroupExpanded(group.name) },
                    set: { _ in preferences.toggleGroupExpanded(group.name) }
                )

                DisclosureGroup(isExpanded: expanded) {
                    ForEach(group.contacts) { contact in
                        ContactRowWithMenu(contact: contact)
                            .onTapGesture(count: 2) {
                                openWindow(id: "chat", value: contact.jid.description)
                            }
                    }
                } label: {
                    Text(group.name)
                }
            }

            if !roomConversations.isEmpty {
                let roomsExpanded = Binding(
                    get: { preferences.isGroupExpanded(roomsSectionKey) },
                    set: { _ in preferences.toggleGroupExpanded(roomsSectionKey) }
                )

                DisclosureGroup(isExpanded: roomsExpanded) {
                    ForEach(roomConversations) { conversation in
                        RoomRowWithMenu(conversation: conversation)
                            .onTapGesture(count: 2) {
                                openWindow(id: "chat", value: conversation.jid.description)
                            }
                    }
                } label: {
                    Text("Rooms")
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("contact-list")
    }

    private var sortedAndFilteredGroups: [ContactGroup] {
        let groups = environment.rosterService.groups

        // Apply search filter
        let searched: [ContactGroup] = if searchText.isEmpty {
            groups
        } else {
            groups.compactMap { group in
                let filtered = group.contacts.filter { contact in
                    contact.displayName.localizedStandardContains(searchText)
                        || contact.jid.description.localizedStandardContains(searchText)
                }
                guard !filtered.isEmpty else { return nil }
                return ContactGroup(id: group.id, name: group.name, contacts: filtered)
            }
        }

        // Filter offline contacts
        let filtered: [ContactGroup] = if preferences.hideOffline {
            searched.compactMap { group in
                let onlineContacts = group.contacts.filter { contact in
                    environment.presenceService.contactPresences[contact.jid] != nil
                }
                guard !onlineContacts.isEmpty else { return nil }
                return ContactGroup(id: group.id, name: group.name, contacts: onlineContacts)
            }
        } else {
            searched
        }

        // Sort contacts within groups
        return filtered.map { group in
            let sorted = sortContacts(group.contacts)
            return ContactGroup(id: group.id, name: group.name, contacts: sorted)
        }
    }

    private func sortContacts(_ contacts: [Contact]) -> [Contact] {
        switch preferences.sortMode {
        case .alphabetical:
            return contacts.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        case .byStatus:
            return contacts.sorted { a, b in
                let aPriority = statusPriority(for: a)
                let bPriority = statusPriority(for: b)
                if aPriority != bPriority {
                    return aPriority < bPriority
                }
                return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }

        case .recentConversation:
            var dateLookup: [String: Date] = [:]
            for conversation in environment.chatService.openConversations {
                if let date = conversation.lastMessageDate {
                    dateLookup[conversation.jid.description] = date
                }
            }
            return contacts.sorted { a, b in
                let aDate = dateLookup[a.jid.description]
                let bDate = dateLookup[b.jid.description]
                if let aDate, let bDate {
                    return aDate > bDate
                }
                if aDate != nil { return true }
                if bDate != nil { return false }
                return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }
        }
    }

    private func statusPriority(for contact: Contact) -> Int {
        guard let status = environment.presenceService.contactPresences[contact.jid] else { return 4 }
        return switch status {
        case .available: 0
        case .away: 1
        case .dnd: 2
        case .xa: 3
        case .offline: 4
        }
    }
}

// MARK: - RoomRowWithMenu

private struct RoomRowWithMenu: View {
    let conversation: Conversation
    @State private var isShowingInviteSheet = false

    var body: some View {
        RoomRow(conversation: conversation)
            .contextMenu {
                RoomContextMenu(
                    conversation: conversation,
                    isShowingInviteSheet: $isShowingInviteSheet
                )
            }
            .sheet(isPresented: $isShowingInviteSheet) {
                InviteUserSheet(conversation: conversation)
            }
    }
}

// MARK: - InviteUserSheet

private struct InviteUserSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation
    @State private var jidString = ""
    @State private var reason = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Invite User")
                .font(.headline)

            TextField("JID (e.g. bob@example.com)", text: $jidString)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

            TextField("Reason (optional)", text: $reason)
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

                Button("Invite") {
                    inviteUser()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(jidString.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 350)
    }

    private func inviteUser() {
        let trimmed = jidString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("@") else {
            errorMessage = "Invalid JID: \(jidString)"
            return
        }
        let reasonText = reason.isEmpty ? nil : reason.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await environment.chatService.inviteUser(
                    jidString: trimmed,
                    toRoomJIDString: conversation.jid.description,
                    reason: reasonText,
                    accountID: conversation.accountID
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
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
