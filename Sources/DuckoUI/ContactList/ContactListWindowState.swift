import DuckoCore
import SwiftUI

/// Transient state for the Contacts window, published as a focused scene value
/// so menu-bar commands can drive the window — revealing the search field and
/// presenting the contact action sheets. Mirrors the way `ChatWindowState`
/// backs the chat window's menu commands.
@MainActor @Observable
public final class ContactListWindowState {
    let preferences = ContactListPreferences()

    var rosterNotice: String?

    var searchText = ""
    var isSearching = false
    var isEditingInviteNickname = false

    var selectedRow: ContactListRow?

    var isShowingAddContact = false
    var isShowingJoinRoom = false
    var isShowingBookmarks = false
    var isShowingProfile = false
    var customStatusPreset: CustomStatusPreset?
    var activeRowSheet: ContactListRowSheet?
    var pendingRemoval: Contact?

    init() {}

    public func toggleSearch() {
        if isSearching {
            endSearch()
        } else {
            isSearching = true
        }
    }

    public func endSearch() {
        isSearching = false
        searchText = ""
    }

    public func addContact() {
        isShowingAddContact = true
    }

    public func joinRoom() {
        isShowingJoinRoom = true
    }

    public func showBookmarks() {
        isShowingBookmarks = true
    }

    public func editProfile() {
        isShowingProfile = true
    }

    // MARK: - Contact Commands

    /// The selected row as a command target, resolving a contact row to the live roster contact.
    public func commandTarget(in environment: AppEnvironment) -> ContactCommandTarget? {
        guard let row = selectedRow, let chatKey = row.selectionKey else { return nil }
        switch row {
        case .header:
            return nil
        case let .contact(_, rowContact):
            guard let contact = environment.rosterService.contact(jidString: rowContact.jid.description, accountID: rowContact.accountID) else {
                return nil
            }
            let conversation = environment.chatService.openConversations.first {
                $0.jid == contact.jid && $0.accountID == contact.accountID
            }
            return ContactCommandTarget(
                contactInfoRef: ContactInfoRef(accountID: contact.accountID, jid: contact.jid.description),
                transcriptRef: ConversationRef(contact: contact, openConversation: conversation),
                chatKey: chatKey,
                contact: contact
            )
        case let .room(room):
            return ContactCommandTarget(
                contactInfoRef: nil,
                transcriptRef: ConversationRef(conversation: room),
                chatKey: chatKey,
                contact: nil
            )
        }
    }

    /// False while search, the invite nickname field, or any Contacts sheet has the keyboard, so ⌘⌫ keeps editing
    /// text there.
    public var canRemoveSelectedContact: Bool {
        guard case .contact? = selectedRow else { return false }
        return !isSearching && !isEditingInviteNickname && !isShowingAddContact && !isShowingJoinRoom && !isShowingBookmarks
            && !isShowingProfile && customStatusPreset == nil && activeRowSheet == nil && pendingRemoval == nil
    }

    public func removeSelectedContact(in environment: AppEnvironment) {
        guard let contact = commandTarget(in: environment)?.contact else { return }
        requestRemoval(of: contact)
    }

    func requestRemoval(of contact: Contact) {
        pendingRemoval = contact
    }

    /// Removes `contact` after the user confirmed. Takes the contact rather than reading `pendingRemoval`, which the
    /// dialog's dismissal clears before this runs.
    func confirmRemoval(_ contact: Contact, environment: AppEnvironment) async {
        do {
            let outcome = try await environment.rosterService.removeContact(contact, accountID: contact.accountID)
            if !outcome.isComplete { presentRosterNotice(outcome.message, accountID: contact.accountID, environment: environment) }
        } catch {
            presentRosterNotice("\(contact.jid): \(error.localizedDescription)", accountID: contact.accountID, environment: environment)
        }
    }

    func presentRosterNotice(_ message: String, accountID: UUID, environment: AppEnvironment) {
        let account = environment.accountService.accounts.first { $0.id == accountID }
        rosterNotice = "\(account?.jid.description ?? accountID.uuidString): \(message)"
    }
}
