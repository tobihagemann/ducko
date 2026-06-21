import AppKit
import DuckoCore
import SwiftUI

private let roomsSectionKey = "__rooms__"

/// Fixed height of a group header row (content + 8pt vertical insets).
private let groupRowHeight: CGFloat = 24

/// Vertical chrome around a contact row's avatar (row insets + `ContactRow`
/// padding + `.plain`'s own row padding); a contact row is `avatarSize` + this.
private let contactRowChrome: CGFloat = 12

/// Row insets, kept equal across headers and contacts (leading 4 / trailing 3)
/// so dots and avatars column-align with the "me" header. `.plain` adds its own
/// ~8pt leading / ~9pt trailing (scroller gutter) on top, landing content at ~12pt.
private let groupRowInsets = EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 3)
private let contactRowInsets = EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 3)

/// Caps on the hidden name-measuring layer so a server-controlled roster (very
/// many entries or pathologically long names) can't drive unbounded layout
/// work. Generous enough not to affect realistic rosters — a name longer than
/// the length cap can't widen the window past `sliderMaxWidth` anyway.
private let maxMeasuredNames = 200
private let maxMeasuredNameLength = 64

/// Cap on the hidden row-measuring layer's row count, the vertical twin of
/// `maxMeasuredNames`, so a server-controlled roster can't drive unbounded
/// layout work. `maxMeasuredRows × plainMinRowHeight` far exceeds `maxListHeight`,
/// so truncating the prefix only drops rows that wouldn't fit anyway —
/// `fittedContentHeight` falls back to the clamped estimate for an overflowing roster.
private let maxMeasuredRows = 200

/// The `.listStyle(.plain)` `List` floors every row at its minimum row height:
/// a short group-header row (content + insets ≈ 22) renders at 24, while taller
/// contact/room rows (avatar/icon-dominated, ≈ 44+) pass through unchanged.
/// Measured empirically by comparing the real list's `.listRowBackground` cell
/// heights against the off-screen replica; mirroring the floor per row makes the
/// summed measurement match the real list exactly, with no per-row-type constant.
private let plainMinRowHeight: CGFloat = 24

struct ContactListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ThemeEngine.self) private var theme
    @Environment(\.openChat) private var openChat
    let searchText: String
    let preferences: ContactListPreferences
    @State private var selection: ConversationKey?
    @State private var measuredContentHeight: CGFloat = 0
    @AppStorage(ContactListSizingDefaults.autoSizeVerticalKey, store: PreferencesDefaults.store)
    private var autoSizeVertical = true
    @AppStorage(ContactListSizingDefaults.autoSizeHorizontalKey, store: PreferencesDefaults.store)
    private var autoSizeHorizontal = true

    private var roomConversations: [Conversation] {
        environment.chatService.openConversations.filter { $0.type == .groupchat }
    }

    /// True when at least one enabled account has reached `.connected`.
    /// UI integration tests poll the matching AX sentinel below to gate on
    /// the live handshake completing — `contact-row-*` can render from the
    /// cached roster before the new client finishes binding, so it is not a
    /// safe connectivity gate by itself.
    private var hasConnectedAccount: Bool {
        environment.accountService.hasAnyConnectedAccount
    }

    var body: some View {
        // Resolve the filtered roster and open rooms once: the rows, the group counts,
        // the height, the width-measuring layer, and the selection reconcile below all
        // read them. Presence is read per contact (account-scoped) rather than from a
        // merged map, so a same-JID peer on two accounts counts under the right account.
        let groups = sortedAndFilteredGroups
        let rooms = roomConversations
        let unfilteredGroups = environment.rosterService.groups
        let contentHeight: CGFloat? = autoSizeVertical
            ? fittedContentHeight(groups: groups, rooms: rooms)
            : nil

        List(selection: $selection) {
            ForEach(groups) { group in
                let counts = ContactListSizing.onlineCounts(
                    groupID: group.id,
                    unfilteredRoster: unfilteredGroups,
                    displayedContacts: group.contacts
                ) { environment.presenceService.presence(for: $0.jid, accountID: $0.accountID) != nil }

                GroupHeaderRow(
                    name: group.name,
                    online: counts.online,
                    total: counts.total,
                    isExpanded: preferences.isGroupExpanded(group.name)
                ) {
                    preferences.toggleGroupExpanded(group.name)
                }
                .listRowInsets(groupRowInsets)
                .listRowSeparator(.hidden)
                .selectionDisabled()

                if preferences.isGroupExpanded(group.name) {
                    ForEach(group.contacts) { contact in
                        selectableRow(id: ConversationKey(accountID: contact.accountID, jid: contact.jid.description)) {
                            ContactRowWithMenu(contact: contact)
                        }
                    }
                }
            }

            if !rooms.isEmpty {
                GroupHeaderRow(
                    name: "Rooms",
                    showCount: false,
                    isExpanded: preferences.isGroupExpanded(roomsSectionKey)
                ) {
                    preferences.toggleGroupExpanded(roomsSectionKey)
                }
                .listRowInsets(groupRowInsets)
                .listRowSeparator(.hidden)
                .selectionDisabled()

                if preferences.isGroupExpanded(roomsSectionKey) {
                    ForEach(rooms) { conversation in
                        selectableRow(id: ConversationKey(accountID: conversation.accountID, jid: conversation.jid.description)) {
                            RoomRowWithMenu(conversation: conversation)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        // Native single-click selection across the whole row; `primaryAction`
        // fires on double-click (and Return) to open the chat. The per-row
        // `.contextMenu` on the rows themselves keeps providing the right-click
        // actions, so the selection menu here is intentionally empty.
        .contextMenu(forSelectionType: ConversationKey.self) { _ in
        } primaryAction: { ids in
            if let id = ids.first {
                openChat(id.jid, accountID: id.accountID)
            }
        }
        .accessibilityIdentifier("contact-list")
        // AX-only connectivity gate at `contact-list`. `.accessibilityValue` propagates to `kAXValueAttribute` on
        // the List's AX element; a Button/overlay sentinel doesn't (SwiftUI elides zero-frame primitives from the
        // AX tree). Tests wait for "connected" because `contact-row-*` can render from cached roster before bind completes.
        .accessibilityValue(hasConnectedAccount ? "connected" : "connecting")
        // Vertical auto-size: when enabled, give the list exactly its content
        // height (capped at the screen) so the enclosing content-size window
        // shrinks/grows to fit the contacts instead of leaving empty space —
        // Adium's auto-sizing buddy list. When disabled, the list fills the
        // (user-resizable) window. Recomputes as groups expand/collapse.
        .frame(height: contentHeight)
        // Horizontal auto-size: measure the widest *visible* (filtered) name
        // off-screen and publish it up to the window via `MaxNameWidthKey`, so
        // a search that narrows to one contact narrows the window too.
        .background(alignment: .topLeading) {
            if autoSizeHorizontal {
                nameMeasuringLayer(names: visibleNames(groups: groups, rooms: rooms))
            }
        }
        // Vertical auto-size measurement: render the visible rows off-screen and
        // sum their real heights via `ContentHeightKey`, feeding `contentHeight`
        // above so the frame fits rows of any height (two-line status, varying
        // `avatarSize`) instead of the flat per-row estimate.
        .background(alignment: .topLeading) {
            if autoSizeVertical {
                rowMeasuringLayer(groups: groups, rooms: rooms)
            }
        }
        .onPreferenceChange(ContentHeightKey.self) { measuredContentHeight = $0 }
        // Drop a selection whose row was filtered or collapsed out of view, so
        // a hidden row doesn't stay logically selected.
        .onChange(of: visibleSelectableIDs(groups: groups, rooms: rooms)) { _, ids in
            if let current = selection, !ids.contains(current) {
                selection = nil
            }
        }
    }

    /// Bridges the view's themed row height into `ContactListSizing.listContentHeight`.
    private func listContentHeight(groups: [ContactGroup], rooms: [Conversation]) -> CGFloat {
        CGFloat(ContactListSizing.listContentHeight(
            groups: groups.map { (contactCount: $0.contacts.count, isExpanded: preferences.isGroupExpanded($0.name)) },
            roomCount: rooms.count,
            roomsExpanded: preferences.isGroupExpanded(roomsSectionKey),
            groupRowHeight: Double(groupRowHeight),
            rowHeight: Double(theme.current.avatarSize + contactRowChrome)
        ))
    }

    /// The list's auto-sized height. On overflow (more than `maxMeasuredRows`
    /// visible rows) the measured sum is only a truncated prefix, so `0` is passed
    /// to take `fittedHeight`'s all-rows fallback — which for a roster that large
    /// clamps to `maxListHeight` and scrolls.
    private func fittedContentHeight(groups: [ContactGroup], rooms: [Conversation]) -> CGFloat {
        let overflowing = measuringRowDescriptors(groups: groups, rooms: rooms).count > maxMeasuredRows
        return CGFloat(ContactListSizing.fittedHeight(
            measuredHeight: overflowing ? 0 : Double(measuredContentHeight),
            fallbackHeight: Double(listContentHeight(groups: groups, rooms: rooms)),
            maxHeight: Double(maxListHeight)
        ))
    }

    /// Upper bound so a long roster scrolls within the window rather than
    /// growing it past the visible screen.
    private var maxListHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 160
    }

    /// A selectable contact/room row. Selection is owned by `List(selection:)`;
    /// double-click and Return open the chat via the list's
    /// `.contextMenu(…primaryAction:)`. The full-width `contentShape` keeps the
    /// whole row hit-testable — the row carries no tap gesture of its own (one
    /// would steal single clicks from the list's selection in the content area).
    private func selectableRow(id: ConversationKey, @ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .listRowInsets(contactRowInsets)
            .listRowSeparator(.hidden)
            .tag(id)
    }

    /// Display names of the rows the list actually renders — contacts in
    /// expanded, filtered groups plus room titles when the rooms section is
    /// open — so the window's width tracks every visible name, not just contacts.
    private func visibleNames(groups: [ContactGroup], rooms: [Conversation]) -> [String] {
        var names = groups
            .filter { preferences.isGroupExpanded($0.name) }
            .flatMap { $0.contacts.map { measuringName(for: $0) } }
        if preferences.isGroupExpanded(roomsSectionKey) {
            names += rooms.map { $0.displayName ?? $0.jid.localPart ?? $0.jid.description }
        }
        return names.prefix(maxMeasuredNames).map { String($0.prefix(maxMeasuredNameLength)) }
    }

    /// The contact's name plus its account-disambiguation label (when its JID is duplicated), so the
    /// window's horizontal auto-fit accounts for the label and doesn't truncate it.
    private func measuringName(for contact: Contact) -> String {
        guard let label = AccountIndicator.label(
            for: contact.accountID, bareJID: contact.jid.description,
            accountService: environment.accountService, rosterService: environment.rosterService
        ) else {
            return contact.displayName
        }
        return "\(contact.displayName)  \(label)"
    }

    /// Row IDs currently rendered (expanded groups' contacts plus open rooms),
    /// used to reconcile `selection` when a filter hides the selected row.
    private func visibleSelectableIDs(groups: [ContactGroup], rooms: [Conversation]) -> Set<ConversationKey> {
        var ids = Set<ConversationKey>()
        for group in groups where preferences.isGroupExpanded(group.name) {
            for contact in group.contacts {
                ids.insert(ConversationKey(accountID: contact.accountID, jid: contact.jid.description))
            }
        }
        if preferences.isGroupExpanded(roomsSectionKey) {
            for room in rooms {
                ids.insert(ConversationKey(accountID: room.accountID, jid: room.jid.description))
            }
        }
        return ids
    }

    /// Off-screen copies of the visible names at intrinsic width, each
    /// publishing its width so `MaxNameWidthKey` tracks the widest — the basis
    /// for the window's horizontal auto-fit. `.fixedSize()` makes each label
    /// ignore the window width so the measurement is the true label width.
    private func nameMeasuringLayer(names: [String]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                Text(name)
                    .fontWeight(.medium)
                    .fixedSize()
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: MaxNameWidthKey.self, value: proxy.size.width)
                        }
                    }
            }
        }
        .hidden()
        .accessibilityHidden(true)
    }

    /// One entry per row the `List` renders, in body order: a header per group,
    /// that group's contacts when expanded, then the Rooms header and rooms when
    /// present and expanded. Shared by the measuring layer (`.prefix(maxMeasuredRows)`)
    /// and `fittedContentHeight`'s overflow count so the two can't drift — the height
    /// twin of `visibleNames` / `visibleSelectableIDs`.
    private func measuringRowDescriptors(groups: [ContactGroup], rooms: [Conversation]) -> [RowDescriptor] {
        var descriptors: [RowDescriptor] = []
        for group in groups {
            descriptors.append(.header)
            if preferences.isGroupExpanded(group.name) {
                descriptors.append(contentsOf: group.contacts.map { .contact($0) })
            }
        }
        if !rooms.isEmpty {
            descriptors.append(.header)
            if preferences.isGroupExpanded(roomsSectionKey) {
                descriptors.append(contentsOf: rooms.map { .room($0) })
            }
        }
        return descriptors
    }

    /// Off-screen copies of the visible rows at their intrinsic height, each
    /// publishing its height so `ContentHeightKey` sums them — the basis for the
    /// window's vertical auto-fit. Renders the *bare* rows (not the menu wrappers,
    /// which carry context menus and an auto-opening settings sheet) and the
    /// decode-free `ContactRow`. `.fixedSize(vertical:)` keeps each row at its
    /// intrinsic height so the framed list's background proposal can't compress
    /// the measurement and feed a shrinking height back into the frame.
    private func rowMeasuringLayer(groups: [ContactGroup], rooms: [Conversation]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(measuringRowDescriptors(groups: groups, rooms: rooms).prefix(maxMeasuredRows).enumerated()), id: \.offset) { _, descriptor in
                measuringRow(for: descriptor)
                    .background { rowHeightReader }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .hidden()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func measuringRow(for descriptor: RowDescriptor) -> some View {
        switch descriptor {
        case .header:
            // The name is irrelevant to height (single line, and floored to
            // `plainMinRowHeight`), so the bare header measures with an empty one.
            GroupHeaderRow(name: "", isExpanded: false, toggle: {})
                .padding(groupRowInsets)
        case let .contact(contact):
            ContactRow(contact: contact, forMeasurement: true)
                .padding(contactRowInsets)
        case let .room(room):
            RoomRow(conversation: room)
                .padding(contactRowInsets)
        }
    }

    private var rowHeightReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: ContentHeightKey.self, value: max(proxy.size.height, plainMinRowHeight))
        }
    }

    private var sortedAndFilteredGroups: [ContactGroup] {
        // Key the last-message map by account+JID: two accounts' conversations with the same peer
        // JID would otherwise collide and the "recent conversation" sort would read the wrong date.
        var lastMessageDates: [ConversationKey: Date] = [:]
        for conversation in environment.chatService.openConversations {
            if let date = conversation.lastMessageDate {
                lastMessageDates[ConversationKey(accountID: conversation.accountID, jid: conversation.jid.description)] = date
            }
        }
        let presenceService = environment.presenceService

        return ContactListFilter.sortedAndFiltered(
            groups: environment.rosterService.groups,
            searchText: searchText,
            hideOffline: preferences.hideOffline,
            sortMode: preferences.sortMode,
            context: ContactListFilter.PresenceContext(
                isOnline: { presenceService.presence(for: $0.jid, accountID: $0.accountID) != nil },
                statusPriority: { statusPriority(of: presenceService.presence(for: $0.jid, accountID: $0.accountID)) },
                lastMessageDate: { lastMessageDates[ConversationKey(accountID: $0.accountID, jid: $0.jid.description)] }
            )
        )
    }

    private func statusPriority(of status: PresenceService.PresenceStatus?) -> Int {
        guard let status else { return 4 }
        return switch status {
        case .available: 0
        case .away: 1
        case .dnd: 2
        case .xa: 3
        case .offline: 4
        }
    }
}

/// Publishes the widest measured contact-name label up the view tree so the
/// enclosing window can size its width to fit (Adium's horizontal auto-fit).
struct MaxNameWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Sums the measured heights of every off-screen row so `ContactListView` can
/// size the list to its real content (Adium's vertical auto-fit). Diverges from
/// `MaxNameWidthKey` only in the reducer: **sum** rather than `max`.
struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

/// One measured row in body order. The measuring layer maps each case to the
/// bare row view (`GroupHeaderRow` / `ContactRow` / `RoomRow`).
private enum RowDescriptor {
    case header
    case contact(Contact)
    case room(Conversation)
}

/// A collapsible group header. The whole row toggles expansion (not just the
/// chevron), matching Adium, and is excluded from list selection by the caller.
private struct GroupHeaderRow: View {
    let name: String
    var online: Int = 0
    var total: Int = 0
    var showCount: Bool = true
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    // Same 8-pt slot as the contact status dots so the chevron's
                    // center aligns with the dot column above/below it.
                    .frame(width: 8)

                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                if showCount {
                    Text("\(online) of \(total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RoomRowWithMenu: View {
    @Environment(AppEnvironment.self) private var environment
    let conversation: Conversation
    @State private var isShowingInviteSheet = false
    @State private var isShowingSettingsSheet = false

    private var isNewlyCreated: Bool {
        guard let accountID = conversation.accountID else { return false }
        return environment.chatService.isRoomNewlyCreated(jidString: conversation.jid.description, accountID: accountID)
    }

    var body: some View {
        RoomRow(conversation: conversation)
            .contextMenu {
                RoomContextMenu(
                    conversation: conversation,
                    isShowingInviteSheet: $isShowingInviteSheet,
                    isShowingSettingsSheet: $isShowingSettingsSheet
                )
            }
            .sheet(isPresented: $isShowingInviteSheet) {
                InviteUserSheet(conversation: conversation)
            }
            .sheet(
                isPresented: $isShowingSettingsSheet,
                onDismiss: {
                    if let accountID = conversation.accountID {
                        environment.chatService.clearNewlyCreatedRoom(conversation.jid.description, accountID: accountID)
                    }
                },
                content: {
                    if let accountID = conversation.accountID {
                        RoomSettingsView(
                            roomJIDString: conversation.jid.description,
                            accountID: accountID
                        )
                    }
                }
            )
            .onChange(of: isNewlyCreated) {
                if isNewlyCreated {
                    isShowingSettingsSheet = true
                }
            }
            .onAppear {
                if isNewlyCreated {
                    isShowingSettingsSheet = true
                }
            }
    }
}

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
        guard let accountID = conversation.accountID else { return }
        Task {
            do {
                try await environment.chatService.inviteUser(
                    jidString: trimmed,
                    toRoomJIDString: conversation.jid.description,
                    reason: reasonText,
                    accountID: accountID
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

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
