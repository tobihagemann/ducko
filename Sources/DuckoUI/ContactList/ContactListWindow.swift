import DuckoCore
import SwiftUI

struct ContactListWindow: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ThemeEngine.self) private var theme
    @Environment(\.openWindow) private var openWindow
    @State private var state = ContactListWindowState()
    @State private var maxNameWidth: CGFloat = 0

    @AppStorage(ContactListSizingDefaults.autoSizeHorizontalKey, store: PreferencesDefaults.store)
    private var autoSizeHorizontal = true
    @AppStorage(ContactListSizingDefaults.maxWidthKey, store: PreferencesDefaults.store)
    private var maxWidthPreference = ContactListSizingDefaults.defaultMaxWidth

    private var account: Account? {
        environment.accountService.accounts.first { $0.isEnabled }
    }

    /// Floor so the "me" header stays comfortable when names are short.
    private static let floorWidth: CGFloat = 200
    /// Fixed row chrome (insets + status dot + spacing + avatar) plus the points
    /// by which a `List` row renders its name wider than the off-screen label,
    /// so a single small gap remains before the avatar.
    private static let rowChrome: CGFloat = 70

    /// The user's Maximum Width preference, clamped to the slider's valid range
    /// (and guarded against a non-finite persisted value) so a stray stored
    /// number can't collapse or invalidate the window frame.
    private var clampedMaxWidth: CGFloat {
        CGFloat(ContactListSizing.clampMaxWidth(maxWidthPreference))
    }

    /// Width that fits the widest visible contact name, capped at the user's
    /// Maximum Width — the horizontal half of Adium's auto-sizing. A `List` is
    /// greedy-width and reports no intrinsic content width, so the width is
    /// derived from the contact-name labels `ContactListView` measures
    /// off-screen and publishes via `MaxNameWidthKey`.
    private var fittedWidth: CGFloat {
        CGFloat(ContactListSizing.fittedWidth(
            maxNameWidth: Double(maxNameWidth),
            avatarSize: Double(theme.current.avatarSize),
            rowChrome: Double(Self.rowChrome),
            floorWidth: Double(Self.floorWidth),
            maxWidth: Double(clampedMaxWidth)
        ))
    }

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            StatusBarView()

            Divider()

            if state.isSearching {
                ContactSearchField(state: state)
                Divider()
            }

            SubscriptionRequestBanner()

            RoomInviteBanner()

            ContactListView(searchText: state.searchText, preferences: state.preferences)
        }
        .frame(
            // Manual mode: cap the floor at the chosen Maximum Width so a
            // sub-floor preference can't invert minWidth above idealWidth.
            minWidth: autoSizeHorizontal ? fittedWidth : min(Self.floorWidth, clampedMaxWidth),
            idealWidth: autoSizeHorizontal ? fittedWidth : clampedMaxWidth,
            maxWidth: autoSizeHorizontal ? fittedWidth : .infinity
        )
        .onPreferenceChange(MaxNameWidthKey.self) { maxNameWidth = $0 }
        .focusedSceneValue(\.contactListWindowState, state)
        .task {
            guard let accountID = account?.id else { return }
            switch environment.accountService.connectionStates[accountID] {
            case .connected:
                break
            default:
                try? await environment.accountService.connect(accountID: accountID)
            }
        }
        .task(id: account?.id) {
            guard let accountID = account?.id else { return }
            try? await environment.chatService.loadConversations(for: accountID)
            try? await environment.rosterService.loadContacts(for: accountID)
            environment.presenceService.startIdleMonitoring(accountID: accountID)
        }
        .sheet(isPresented: $state.isShowingNewChat) {
            NewChatSheet { jidString in
                openWindow(id: "chat", value: jidString)
            }
        }
        .sheet(isPresented: $state.isShowingAddContact) {
            AddContactSheet()
        }
        .sheet(isPresented: $state.isShowingJoinRoom) {
            RoomJoinDialog { jidString in
                openWindow(id: "chat", value: jidString)
            }
        }
        .sheet(isPresented: $state.isShowingBookmarks) {
            NavigationStack {
                BookmarkListView()
            }
            .frame(minWidth: 400, minHeight: 300)
        }
        .sheet(isPresented: $state.isShowingProfile) {
            ProfileEditView()
        }
        .alert(
            "Certificate Changed",
            isPresented: Binding(
                get: { !environment.accountService.certificateWarnings.isEmpty },
                set: { newValue in
                    if !newValue, let id = environment.accountService.certificateWarnings.keys.first {
                        Task { await environment.accountService.rejectNewCertificate(for: id) }
                    }
                }
            )
        ) {
            Button("Trust New Certificate") {
                if let id = environment.accountService.certificateWarnings.keys.first {
                    environment.accountService.trustNewCertificate(for: id)
                }
            }
            Button("Disconnect", role: .destructive) {
                if let id = environment.accountService.certificateWarnings.keys.first {
                    Task { await environment.accountService.rejectNewCertificate(for: id) }
                }
            }
        } message: {
            if let warning = environment.accountService.certificateWarnings.values.first {
                Text("The TLS certificate for \(warning.accountJID) has changed.\n\nPrevious: \(warning.previousFingerprint)\nNew: \(warning.newFingerprint)")
            }
        }
    }
}

/// Search field revealed by ⌘F (Find). Takes focus on appear and dismisses on
/// Escape, clearing the query so the list returns to its full state.
private struct ContactSearchField: View {
    @Bindable var state: ContactListWindowState
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                // Center the glyph in the same 8-pt column as the contact
                // status dots so the icon and query text line up with the
                // dot/name columns of the rows below.
                .frame(width: 8)

            TextField("Search", text: $state.searchText)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onExitCommand { state.endSearch() }
                .accessibilityIdentifier("contact-search-field")

            if !state.searchText.isEmpty {
                Button {
                    state.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Defer focus one main-actor turn: vertical auto-size grows the window
        // as this field is inserted, and that frame change clears first
        // responder if focus is set synchronously in the same pass.
        .onAppear {
            Task { @MainActor in isFocused = true }
        }
    }
}
