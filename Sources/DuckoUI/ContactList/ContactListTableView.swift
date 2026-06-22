import AppKit
import DuckoCore
import QuartzCore
import SwiftUI

/// Shared width bounds for the auto-sizing contact-list window. The coordinator
/// targets these and `ContactListWindow` derives its content-minimum from the
/// same `floor` so AppKit's min-size clamp can't fight the coordinator's
/// animated width.
enum ContactListWidthMetrics {
    /// Floor so the "me" header stays comfortable when names are short.
    static let floor: CGFloat = 200
    /// Fixed row chrome (insets + status dot + spacing + avatar) added to the
    /// widest measured name to reach the window width.
    static let rowChrome: CGFloat = 70
}

/// Caps on name and row measurement so a server-controlled roster (very many
/// entries or pathologically long names) can't drive unbounded layout work.
private let maxMeasuredNames = 200
private let maxMeasuredNameLength = 64
private let maxMeasuredRows = 200

/// Flat per-row height estimate, used as `fittedHeight`'s fallback for an
/// overflowing roster (clamps up to the screen cap) and an empty one (collapses
/// to zero), and for rows past the measurement cap.
private let estimatedRowChrome: CGFloat = 12

/// AppKit contact list: a view-based `NSTableView` whose cells host the
/// SwiftUI rows, owning both the animated row diff and a top-left-anchored
/// `NSWindow` frame resize so the two co-animate in one transaction.
@MainActor
struct ContactListTableView: NSViewRepresentable {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ThemeEngine.self) private var theme
    @Environment(\.openChat) private var openChat
    @Environment(\.openWindow) private var openWindow
    @Environment(TranscriptScope.self) private var transcriptScope

    let rows: [ContactListRow]
    let preferences: ContactListPreferences
    let chromeHeight: CGFloat
    let autoSizeVertical: Bool
    let autoSizeHorizontal: Bool
    let maxWidthPreference: Double
    let hasConnectedAccount: Bool
    let presentSheet: (ContactListRowSheet) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.makeContainer()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.environment = environment
        coordinator.theme = theme
        coordinator.openChat = openChat
        coordinator.openWindow = openWindow
        coordinator.transcriptScope = transcriptScope
        coordinator.presentSheet = presentSheet
        coordinator.preferences = preferences
        coordinator.incomingRows = rows
        coordinator.chromeHeight = chromeHeight
        coordinator.autoSizeVertical = autoSizeVertical
        coordinator.autoSizeHorizontal = autoSizeHorizontal
        coordinator.maxWidthPreference = maxWidthPreference
        coordinator.hasConnectedAccount = hasConnectedAccount
        coordinator.reconcile()
    }

    /// Owns the table, the row diff, selection-to-open routing, name/height
    /// measurement, and the co-animated window-frame resize. Subclasses
    /// `NSObject` solely to adopt the AppKit table/menu delegate protocols.
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var environment: AppEnvironment?
        var theme: ThemeEngine?
        var openChat = OpenChatAction { _, _ in }
        var openWindow: OpenWindowAction?
        var transcriptScope: TranscriptScope?
        var presentSheet: (ContactListRowSheet) -> Void = { _ in }
        var preferences: ContactListPreferences?
        var incomingRows: [ContactListRow] = []
        var chromeHeight: CGFloat = 0
        var autoSizeVertical = true
        var autoSizeHorizontal = true
        var maxWidthPreference = ContactListSizingDefaults.defaultMaxWidth
        var hasConnectedAccount = false

        private var rows: [ContactListRow] = []
        private var rowHeights: [CGFloat] = []
        private var lastAppliedKey: ContactListResize.LayoutKey?
        private var pendingInitialApply = true
        private var measuringHost: NSHostingView<ContactListCellContent>?
        private let resizeGate = ContactListResizeGate()
        private var didInstallGate = false

        isolated deinit {
            // Restore SwiftUI's original window delegate if we proxied it.
            if didInstallGate, let window = tableView?.window, window.delegate === resizeGate {
                window.delegate = resizeGate.downstream
            }
        }

        private weak var container: NSView?
        private weak var scrollView: NSScrollView?
        private weak var tableView: ContactListTableControl?

        private static let cellIdentifier = NSUserInterfaceItemIdentifier("contact-cell")

        // MARK: - View construction

        func makeContainer() -> NSView {
            let table = ContactListTableControl()
            table.headerView = nil
            table.style = .plain
            table.backgroundColor = .clear
            table.selectionHighlightStyle = .regular
            table.allowsEmptySelection = true
            table.allowsMultipleSelection = false
            table.intercellSpacing = NSSize(width: 0, height: 0)
            table.usesAutomaticRowHeights = false
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("contact"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.dataSource = self
            table.delegate = self
            table.onOpenRow = { [weak self] in self?.openRow($0) }
            table.onReturn = { [weak self] in self?.openSelectedRow() }
            // Setting the table's own menu (populated per-row by the delegate)
            // lets NSTableView's default contextual-menu path draw the native
            // rounded emphasis on the clicked row.
            let contextMenu = NSMenu()
            contextMenu.delegate = self
            table.menu = contextMenu

            let scrollView = NSScrollView()
            scrollView.documentView = table
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            scrollView.automaticallyAdjustsContentInsets = false

            let container = NSView()
            container.addSubview(scrollView)
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: container.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            // Re-expose the connectivity gate the integration harness polls:
            // `contact-list` identifier + `connected`/`connecting` value on a
            // container element whose descendants are the table's rows.
            container.setAccessibilityElement(true)
            container.setAccessibilityRole(.group)
            container.setAccessibilityIdentifier("contact-list")
            container.setAccessibilityValue(hasConnectedAccount ? "connected" : "connecting")

            self.container = container
            self.scrollView = scrollView
            tableView = table
            return container
        }

        // MARK: - Reconciliation

        func reconcile() {
            guard let theme, environment != nil, preferences != nil,
                  let tableView, let scrollView else { return }

            container?.setAccessibilityValue(hasConnectedAccount ? "connected" : "connecting")

            let contentWidth = resolvedContentWidth()
            let measureCount = min(incomingRows.count, maxMeasuredRows)
            let measuredHeights = (0 ..< measureCount).map { measureHeight(for: incomingRows[$0], width: contentWidth) }
            let flatRowHeight = theme.current.avatarSize + estimatedRowChrome
            let newHeights = (0 ..< incomingRows.count).map { $0 < measureCount ? measuredHeights[$0] : flatRowHeight }
            let listHeight = targetListHeight(
                measuredHeights: measuredHeights,
                totalRowCount: incomingRows.count,
                flatRowHeight: flatRowHeight
            )

            // Auto-size mode fits the window to the roster, so a scroller is only
            // needed when the roster exceeds the screen cap; keeping it off
            // otherwise avoids the overlay scroller flashing over the trailing
            // avatars while rows insert/remove during a resize. Manual mode lets
            // the user shrink the window below the roster, so the scroller must
            // stay available there.
            scrollView.hasVerticalScroller = !autoSizeVertical || listHeight >= maxListHeight

            let window = tableView.window
            let targetContentSize = targetContentSize(window: window, contentWidth: contentWidth, listHeight: listHeight)
            let scale = window?.backingScaleFactor ?? scrollView.window?.backingScaleFactor ?? 2
            let key = ContactListResize.LayoutKey(
                rowIDs: incomingRows.map(\.id),
                contentSize: targetContentSize,
                scale: scale
            )
            // A matching key means geometry is unchanged, but a value-passed
            // field (not read reactively) like a group header's online count can
            // still differ, so re-host the visible cells. `rowIDs` are part of the
            // key, so they're identical on a bail and swapping rows is safe.
            guard key != lastAppliedKey else {
                refreshPersistingCells(newRows: incomingRows)
                rows = incomingRows
                return
            }

            applyLayout(newHeights: newHeights, targetContentSize: targetContentSize, key: key, window: window, tableView: tableView)
        }

        /// Target *content* size after per-axis gating: an auto-size-on axis
        /// takes its computed target (width clamped to the shared lower bound),
        /// a manual axis carries the window's current value so `setFrame` is a
        /// no-op there. The vertical target adds the title-bar inset because the
        /// Contacts window uses a full-size content view — SwiftUI insets its
        /// content below the title bar's safe area, so the frame's content area
        /// must reserve that strip on top of `chrome + list`.
        private func targetContentSize(window: NSWindow?, contentWidth: CGFloat, listHeight: CGFloat) -> CGSize {
            let currentContentSize = window.map { $0.contentRect(forFrameRect: $0.frame).size }
            let minContentWidth = min(ContactListWidthMetrics.floor, clampedMaxWidth)
            let width = autoSizeHorizontal ? max(contentWidth, minContentWidth) : (currentContentSize?.width ?? contentWidth)
            let autoHeight = chromeHeight + listHeight + titlebarInset(window)
            let height = autoSizeVertical ? autoHeight : (currentContentSize?.height ?? autoHeight)
            return CGSize(width: width, height: height)
        }

        /// Strip the full-size-content title bar reserves above SwiftUI's safe
        /// area. Constant for a given window regardless of its size.
        private func titlebarInset(_ window: NSWindow?) -> CGFloat {
            guard let window, let contentView = window.contentView else { return 0 }
            return max(0, contentView.frame.height - window.contentLayoutRect.height)
        }

        /// Applies the new rows and target frame. The first pass (and Reduce
        /// Motion) applies non-animated; every later pass co-animates the row
        /// diff and the top-left-anchored frame in one `NSAnimationContext`.
        private func applyLayout(
            newHeights: [CGFloat],
            targetContentSize: CGSize,
            key: ContactListResize.LayoutKey,
            window: NSWindow?,
            tableView: ContactListTableControl
        ) {
            let oldIDs = rows.map(\.id)
            let newIDs = incomingRows.map(\.id)
            let heightsChanged = newHeights != rowHeights

            guard let window else {
                rows = incomingRows
                rowHeights = newHeights
                tableView.reloadData()
                return
            }
            lastAppliedKey = key
            installResizeGate(on: window)

            let drivesFrame = autoSizeVertical || autoSizeHorizontal
            let targetFrame: CGRect? = drivesFrame ? frame(for: targetContentSize, window: window) : nil
            let animate = !pendingInitialApply && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            pendingInitialApply = false

            guard animate else {
                rows = incomingRows
                rowHeights = newHeights
                tableView.reloadData()
                if let targetFrame { setFrameAllowingResize(window, targetFrame) }
                return
            }

            // Co-animate the row insert/remove and the window frame in one
            // transaction (same duration), so the child rows slide up into the
            // group header on collapse and down out of it on expand, in lockstep
            // with the window edge. `allowProgrammaticResize` lets the gate's
            // `windowWillResize` pass this through while still vetoing user drags.
            refreshPersistingCells(newRows: incomingRows)
            rows = incomingRows
            rowHeights = newHeights
            resizeGate.allowProgrammaticResize = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = targetFrame.map { window.animationResizeTime($0) } ?? 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                if oldIDs != newIDs {
                    applyRowDiff(old: oldIDs, new: newIDs)
                } else if heightsChanged {
                    tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< rows.count))
                }
                if let targetFrame {
                    window.animator().setFrame(targetFrame, display: true)
                }
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.resizeGate.allowProgrammaticResize = false }
            }
        }

        /// `setFrame` with the resize gate temporarily allowing it (the gate
        /// otherwise pins a locked axis, so a programmatic set would be vetoed).
        private func setFrameAllowingResize(_ window: NSWindow, _ frame: CGRect) {
            resizeGate.allowProgrammaticResize = true
            window.setFrame(frame, display: true)
            resizeGate.allowProgrammaticResize = false
        }

        /// Installs the window-delegate proxy that vetoes user resize on the
        /// auto-size axes. SwiftUI re-asserts `.resizable` / `contentMaxSize` /
        /// `styleMask`, so `windowWillResize` is the only hook that holds; the
        /// proxy forwards every other delegate message to SwiftUI's delegate.
        private func installResizeGate(on window: NSWindow) {
            resizeGate.lockWidth = autoSizeHorizontal
            resizeGate.lockHeight = autoSizeVertical
            guard !didInstallGate else { return }
            if window.delegate !== resizeGate {
                resizeGate.downstream = window.delegate
                window.delegate = resizeGate
            }
            didInstallGate = true
        }

        private func applyRowDiff(old: [String], new: [String]) {
            guard let tableView else { return }
            let diff = new.difference(from: old)
            var removals = IndexSet()
            var insertions = IndexSet()
            for change in diff {
                switch change {
                case let .remove(offset, _, _): removals.insert(offset)
                case let .insert(offset, _, _): insertions.insert(offset)
                }
            }
            // Slide vertically so children move into/out of the group header
            // (collapse slides up, expand slides down), the standard disclosure
            // motion — in lockstep with the window edge via the shared context.
            tableView.beginUpdates()
            if !removals.isEmpty { tableView.removeRows(at: removals, withAnimation: .slideUp) }
            if !insertions.isEmpty { tableView.insertRows(at: insertions, withAnimation: .slideDown) }
            tableView.endUpdates()
        }

        /// Re-host cells whose backing row kept its identity but changed content
        /// — a group header's chevron and count on collapse/expand. The row diff
        /// only (re)builds inserted rows, so a header that stays put would keep
        /// its stale `isExpanded`. Matches each realized view by its current
        /// (pre-swap) index to the new row of the same id, so it must run before
        /// `rows` is replaced.
        private func refreshPersistingCells(newRows: [ContactListRow]) {
            guard let tableView else { return }
            let newByID = Dictionary(newRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            tableView.enumerateAvailableRowViews { _, index in
                guard rows.indices.contains(index),
                      let newRow = newByID[rows[index].id],
                      let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ContactListCellView,
                      let content = cellContent(for: newRow) else { return }
                cell.update(content: content)
            }
        }

        private func frame(for contentSize: CGSize, window: NSWindow) -> CGRect {
            let frameSize = window.frameRect(forContentRect: CGRect(origin: .zero, size: contentSize)).size
            return ContactListResize.topLeftAnchoredFrame(current: window.frame, targetSize: frameSize)
        }

        // MARK: - Measurement

        private var clampedMaxWidth: CGFloat {
            CGFloat(ContactListSizing.clampMaxWidth(maxWidthPreference))
        }

        private var maxListHeight: CGFloat {
            (NSScreen.main?.visibleFrame.height ?? 800) - 160
        }

        /// Content width the rows render at: the auto-fit width when horizontal
        /// auto-size is on, otherwise the window's current content width (the
        /// coordinator never drives a manual axis).
        private func resolvedContentWidth() -> CGFloat {
            guard let theme else { return ContactListWidthMetrics.floor }
            if autoSizeHorizontal {
                return CGFloat(ContactListSizing.fittedWidth(
                    maxNameWidth: Double(measuredMaxNameWidth()),
                    avatarSize: Double(theme.current.avatarSize),
                    rowChrome: Double(ContactListWidthMetrics.rowChrome),
                    floorWidth: Double(ContactListWidthMetrics.floor),
                    maxWidth: Double(clampedMaxWidth)
                ))
            }
            if let window = tableView?.window {
                return window.contentRect(forFrameRect: window.frame).width
            }
            return scrollView?.bounds.width ?? ContactListWidthMetrics.floor
        }

        /// Widest visible name plus its account-disambiguation label, measured
        /// with the row font. Capped so a pathological roster can't drive
        /// unbounded measurement.
        private func measuredMaxNameWidth() -> CGFloat {
            guard let environment else { return 0 }
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            var maxWidth: CGFloat = 0
            var measured = 0
            for row in incomingRows where measured < maxMeasuredNames {
                let name: String? = switch row {
                case .header:
                    nil
                case let .contact(_, contact):
                    measuringName(for: contact, environment: environment)
                case let .room(room):
                    room.displayTitle
                }
                guard let name else { continue }
                let capped = String(name.prefix(maxMeasuredNameLength))
                maxWidth = max(maxWidth, (capped as NSString).size(withAttributes: attributes).width)
                measured += 1
            }
            return maxWidth
        }

        private func measuringName(for contact: Contact, environment: AppEnvironment) -> String {
            guard let label = AccountIndicator.label(
                for: contact.accountID, bareJID: contact.jid.description,
                accountService: environment.accountService, rosterService: environment.rosterService
            ) else {
                return contact.displayName
            }
            return "\(contact.displayName)  \(label)"
        }

        /// Self-sized height of one row at the target content width, via a
        /// reused off-screen `NSHostingView`.
        private func measureHeight(for row: ContactListRow, width: CGFloat) -> CGFloat {
            guard let content = cellContent(for: row) else {
                return (theme?.current.avatarSize ?? 40) + estimatedRowChrome
            }
            let host: NSHostingView<ContactListCellContent>
            if let measuringHost {
                host = measuringHost
                host.rootView = content
            } else {
                host = NSHostingView(rootView: content)
                measuringHost = host
            }
            host.setFrameSize(NSSize(width: width, height: 0))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }

        /// The list's auto-sized height. An overflowing roster (more than
        /// `maxMeasuredRows`) takes `fittedHeight`'s fallback — which clamps to
        /// the screen cap and scrolls — instead of a truncated measured sum.
        private func targetListHeight(measuredHeights: [CGFloat], totalRowCount: Int, flatRowHeight: CGFloat) -> CGFloat {
            let overflowing = totalRowCount > maxMeasuredRows
            let measured = overflowing ? 0 : measuredHeights.reduce(0, +)
            return CGFloat(ContactListSizing.fittedHeight(
                measuredHeight: Double(measured),
                fallbackHeight: Double(CGFloat(totalRowCount) * flatRowHeight),
                maxHeight: Double(maxListHeight)
            ))
        }

        // MARK: - Cell content

        private func cellContent(for row: ContactListRow) -> ContactListCellContent? {
            guard let environment, let theme else { return nil }
            return ContactListCellContent(
                row: row,
                environment: environment,
                theme: theme,
                openChat: openChat,
                toggle: { [weak self] sectionKey in self?.preferences?.toggleGroupExpanded(sectionKey) },
                showMenu: { [weak self] in self?.showAccessibilityMenu(forRowID: row.id) }
            )
        }

        /// Opens the row's context menu in response to an AX/VoiceOver show-menu
        /// action (the mouse path is the table-owned `NSMenu`, which draws the
        /// native emphasis; the SwiftUI element carrying `contact-row-*` can't
        /// reach that menu, so this bridges it). Deferred to the next runloop
        /// tick: `NSMenu.popUp` runs a modal tracking loop, so opening it inline
        /// would block the out-of-process AX action call until dismissal and the
        /// menu would never be observed.
        private func showAccessibilityMenu(forRowID id: String) {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.presentRowMenu(forRowID: id) }
            }
        }

        private func presentRowMenu(forRowID id: String) {
            guard let tableView, let index = rows.firstIndex(where: { $0.id == id }),
                  let menu = contextMenu(forRow: index) else { return }
            let rowRect = tableView.rect(ofRow: index)
            menu.popUp(positioning: nil, at: NSPoint(x: rowRect.midX, y: rowRect.midY), in: tableView)
        }

        // MARK: - Selection / open

        private func openRow(_ index: Int) {
            guard rows.indices.contains(index), let key = rows[index].selectionKey else { return }
            openChat(key.jid, accountID: key.accountID)
        }

        private func openSelectedRow() {
            guard let tableView, tableView.selectedRow >= 0 else { return }
            openRow(tableView.selectedRow)
        }

        // MARK: - Context menu (NSMenuDelegate)

        /// Populates the table-owned menu for the right-clicked row just before
        /// it opens. Because the menu is table-owned, `NSTableView`'s default
        /// contextual path draws the native rounded emphasis on `clickedRow`.
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView else { return }
            let clickedRow = tableView.clickedRow
            guard let built = contextMenu(forRow: clickedRow) else { return }
            let items = built.items
            built.removeAllItems()
            for item in items {
                menu.addItem(item)
            }
        }

        /// Builds the row's right-click menu as an AppKit `NSMenu`. Item titles
        /// and AX identifiers must stay in sync with the integration suite that
        /// polls them; the sheets are SwiftUI, presented via `presentSheet`.
        private func contextMenu(forRow index: Int) -> NSMenu? {
            guard rows.indices.contains(index), let environment else { return nil }
            switch rows[index] {
            case .header:
                return nil
            case let .contact(_, contact):
                return contactMenu(for: contact, environment: environment)
            case let .room(room):
                return roomMenu(for: room, environment: environment)
            }
        }

        private func contactMenu(for contact: Contact, environment: AppEnvironment) -> NSMenu {
            let conversation = environment.chatService.openConversations.first {
                $0.jid == contact.jid && $0.accountID == contact.accountID
            }
            let menu = NSMenu()
            menu.addItem(item("Start Chat") { [weak self] in
                self?.openChat(contact.jid.description, accountID: contact.accountID)
            })
            menu.addItem(item("Get Info", identifier: "contact-context-get-info") { [weak self] in
                self?.openWindow?(id: "contact-info", value: ContactInfoRef(accountID: contact.accountID, jid: contact.jid.description))
            })
            menu.addItem(item("History", identifier: "contact-context-history") { [weak self] in
                let ref = conversation.map { ConversationRef(conversation: $0) }
                    ?? ConversationRef(accountID: contact.accountID, jid: contact.jid.description, type: .chat)
                self?.transcriptScope?.request(ref)
                self?.openWindow?(id: "transcripts")
            })
            menu.addItem(.separator())
            if let conversation {
                for menuItem in pinMuteItems(for: conversation, accountID: contact.accountID, environment: environment) {
                    menu.addItem(menuItem)
                }
                menu.addItem(.separator())
            }
            menu.addItem(item("Rename…") { [weak self] in
                self?.presentSheet(.rename(contact))
            })
            menu.addItem(item("Send Directed Presence", identifier: "send-directed-presence-menu-item") {
                Task { try? await environment.presenceService.sendDirectedPresence(to: contact.jid.description, accountID: contact.accountID) }
            })
            menu.addItem(.separator())
            menu.addItem(item(contact.isBlocked ? "Unblock" : "Block") {
                Task {
                    if contact.isBlocked {
                        try? await environment.rosterService.unblockContact(jidString: contact.jid.description, accountID: contact.accountID)
                    } else {
                        try? await environment.rosterService.blockContact(jidString: contact.jid.description, accountID: contact.accountID)
                    }
                }
            })
            menu.addItem(item("Remove Contact") {
                Task { try? await environment.rosterService.removeContact(contact, accountID: contact.accountID) }
            })
            return menu
        }

        private func roomMenu(for conversation: Conversation, environment: AppEnvironment) -> NSMenu {
            let menu = NSMenu()
            menu.addItem(item("Open Chat") { [weak self] in
                self?.openChat(conversation.jid.description, accountID: conversation.accountID)
            })
            guard let accountID = conversation.accountID else { return menu }
            menu.addItem(.separator())
            for menuItem in pinMuteItems(for: conversation, accountID: accountID, environment: environment) {
                menu.addItem(menuItem)
            }
            menu.addItem(.separator())
            menu.addItem(item("Invite User…") { [weak self] in
                self?.presentSheet(.invite(conversation))
            })
            if canManageRoom(conversation, accountID: accountID, environment: environment) {
                menu.addItem(.separator())
                menu.addItem(item("Room Settings…", identifier: "room-settings-menu-item") { [weak self] in
                    self?.presentSheet(.roomSettings(conversation))
                })
            }
            menu.addItem(.separator())
            menu.addItem(item("Leave Room") {
                Task { try? await environment.chatService.leaveRoom(jidString: conversation.jid.description, accountID: accountID) }
            })
            return menu
        }

        /// The Pin/Unpin + Mute/Unmute pair shared by the contact and room menus.
        private func pinMuteItems(for conversation: Conversation, accountID: UUID, environment: AppEnvironment) -> [NSMenuItem] {
            [
                item(conversation.isPinned ? "Unpin" : "Pin") {
                    Task { try? await environment.chatService.togglePin(conversationID: conversation.id, accountID: accountID) }
                },
                item(conversation.isMuted ? "Unmute" : "Mute") {
                    Task { try? await environment.chatService.toggleMute(conversationID: conversation.id, accountID: accountID) }
                }
            ]
        }

        private func canManageRoom(_ conversation: Conversation, accountID: UUID, environment: AppEnvironment) -> Bool {
            guard let nickname = conversation.roomNickname else { return false }
            let participants = environment.chatService.participants(forRoomJIDString: conversation.jid.description, accountID: accountID)
            return participants.first { $0.nickname == nickname }?.affiliation == .owner
        }

        /// One menu item whose action runs `run` via the single `@objc`
        /// trampoline (closures aren't valid `NSMenuItem` actions; this is the
        /// minimal target/action footprint).
        private func item(_ title: String, identifier: String? = nil, run: @escaping @MainActor () -> Void) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: #selector(performMenuItem(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = MenuCommand(run)
            if let identifier {
                menuItem.setAccessibilityIdentifier(identifier)
            }
            return menuItem
        }

        @objc private func performMenuItem(_ sender: NSMenuItem) {
            (sender.representedObject as? MenuCommand)?.run()
        }

        // MARK: - NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        // MARK: - NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let content = cellContent(for: rows[row]) else { return nil }
            if let reused = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? ContactListCellView {
                reused.update(content: content)
                return reused
            }
            let cell = ContactListCellView(content: content)
            cell.identifier = Self.cellIdentifier
            return cell
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            rowHeights.indices.contains(row) ? rowHeights[row] : (theme?.current.avatarSize ?? 40) + estimatedRowChrome
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            rows.indices.contains(row) ? rows[row].isSelectable : false
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            rows.indices.contains(row) ? rows[row].typeSelectString : nil
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            false
        }
    }
}

/// View-based `NSTableView` that owns keyboard (Return-to-open),
/// double-click-to-open, and the per-row right-click menu. Keyboard and
/// double-click stay selector-free closures; the menu is a table-owned
/// `NSMenu` so `NSTableView` draws its native rounded context emphasis.
final class ContactListTableControl: NSTableView {
    var onOpenRow: ((Int) -> Void)?
    var onReturn: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        // Return / keypad Enter opens the selected row's chat; arrows and
        // type-select stay the table's own.
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        if clickedRow >= 0 { onOpenRow?(clickedRow) }
    }
}

/// Boxes a `@MainActor` closure so it can ride an `NSMenuItem.representedObject`
/// and be invoked by the coordinator's single `@objc` action trampoline.
@MainActor
final class MenuCommand {
    let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) {
        self.run = run
    }
}

/// Window-delegate proxy that vetoes a USER resize on each locked (auto-size)
/// axis via `windowWillResize`, while letting the coordinator's own animated
/// `setFrame` through (`allowProgrammaticResize`). This is the only hook that
/// actually holds — SwiftUI re-asserts `.windowResizability` / `styleMask` /
/// `contentMaxSize`. Every other delegate message is forwarded to SwiftUI's
/// original delegate so scene behavior (close, restoration, etc.) is preserved.
@MainActor
final class ContactListResizeGate: NSObject, NSWindowDelegate {
    weak var downstream: NSWindowDelegate?
    var lockWidth = false
    var lockHeight = false
    var allowProgrammaticResize = false

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !allowProgrammaticResize else { return frameSize }
        var size = frameSize
        if lockWidth { size.width = sender.frame.width }
        if lockHeight { size.height = sender.frame.height }
        return size
    }

    /// Suppress the edge resize cursor when both axes are locked: SwiftUI keeps
    /// re-adding `.resizable` (a one-time removal doesn't hold), so re-remove it
    /// here whenever it reappears. `windowWillResize` already vetoes the resize;
    /// this just stops the misleading cursor. Programmatic `setFrame` works
    /// without `.resizable`, so the coordinator's animation is unaffected. Mixed
    /// auto/manual modes keep `.resizable` (the manual axis stays draggable) and
    /// rely on the per-axis veto.
    func windowDidUpdate(_ notification: Notification) {
        guard lockWidth, lockHeight, let window = notification.object as? NSWindow,
              window.styleMask.contains(.resizable) else { return }
        window.styleMask.remove(.resizable)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (downstream?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        super.responds(to: aSelector) ? self : downstream
    }
}

/// `NSTableCellView` hosting one SwiftUI contact-list row, pinned to the cell
/// so the table's measured row height and the SwiftUI fitting size agree.
final class ContactListCellView: NSTableCellView {
    private let host: NSHostingView<ContactListCellContent>

    init(content: ContactListCellContent) {
        self.host = NSHostingView(rootView: content)
        super.init(frame: .zero)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(content: ContactListCellContent) {
        host.rootView = content
    }
}

/// The single concrete SwiftUI view a hosted cell renders, switching on the row
/// kind and re-injecting the environments the hosted wrappers depend on. One
/// type keeps `NSHostingView<ContactListCellContent>` concrete (no `AnyView`).
struct ContactListCellContent: View {
    let row: ContactListRow
    let environment: AppEnvironment
    let theme: ThemeEngine
    let openChat: OpenChatAction
    let toggle: (String) -> Void
    let showMenu: () -> Void

    var body: some View {
        rowView
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .environment(environment)
            .environment(theme)
            .environment(\.openChat, openChat)
    }

    @ViewBuilder
    private var rowView: some View {
        switch row {
        case let .header(header):
            GroupHeaderRow(
                name: header.title,
                online: header.online,
                total: header.total,
                showCount: header.showCount,
                isExpanded: header.isExpanded
            ) {
                toggle(header.sectionKey)
            }
            .padding(.vertical, 4)
        case let .contact(_, contact):
            ContactRow(contact: contact)
                // AX-only show-menu (not `.contextMenu`, which would claim the
                // mouse path and suppress the table's native emphasis). Bridges
                // VoiceOver's show-menu on the row to the table-owned menu.
                .accessibilityAction(.showMenu, showMenu)
                .padding(.vertical, 2)
        case let .room(room):
            RoomRow(conversation: room)
                .accessibilityAction(.showMenu, showMenu)
                .padding(.vertical, 2)
        }
    }
}
