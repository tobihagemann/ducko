import SwiftUI

/// The Contacts-window "View" options (sort order + hide-offline) rendered as
/// menu items. Lives in DuckoUI so the `ContactListPreferences` internals stay
/// encapsulated; DuckoApp drops it into the View menu via a `CommandGroup`.
public struct ContactListViewOptionsMenu: View {
    private let state: ContactListWindowState

    public init(state: ContactListWindowState) {
        self.state = state
    }

    public var body: some View {
        @Bindable var preferences = state.preferences

        Picker("Sort Contacts", selection: $preferences.sortMode) {
            ForEach(ContactListSortMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .accessibilityIdentifier("sort-mode-menu")

        Toggle("Hide Offline Contacts", isOn: $preferences.hideOffline)
    }
}
