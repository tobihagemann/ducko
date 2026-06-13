import SwiftUI

/// Transient state for the Contacts window, published as a focused scene value
/// so menu-bar commands can drive the window — revealing the search field and
/// presenting the contact action sheets. Mirrors the way `ChatWindowState`
/// backs the chat window's menu commands.
@MainActor @Observable
public final class ContactListWindowState {
    let preferences = ContactListPreferences()

    var searchText = ""
    var isSearching = false

    var isShowingNewChat = false
    var isShowingAddContact = false
    var isShowingJoinRoom = false
    var isShowingBookmarks = false
    var isShowingProfile = false

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

    public func newChat() {
        isShowingNewChat = true
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
}
