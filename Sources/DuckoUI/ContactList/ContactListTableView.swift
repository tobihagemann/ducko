import AppKit
import DuckoCore
import QuartzCore
import SwiftUI

/// Caps on name and row measurement so a server-controlled roster (very many
/// entries or pathologically long names) can't drive unbounded layout work.
private let maxMeasuredNames = 200
private let maxMeasuredNameLength = 64
private let maxMeasuredRows = 200

/// Flat per-row height estimate, used as `fittedHeight`'s fallback for an
/// overflowing roster (clamps up to the screen cap) and an empty one (collapses
/// to zero), and for rows past the measurement cap.
private let estimatedRowChrome: CGFloat = 12

/// The inputs the SwiftUI `ContactListTableView` pushes into its coordinator on
/// each `updateNSView`, bundled into one value so the push is a single
/// assignment rather than a property-by-property triple-touch (declare, assign,
/// read). `@MainActor` because the ref/closure inputs never leave the main
/// actor; each property keeps its prior per-var default so `Inputs()` reproduces
/// the coordinator's initial state.
@MainActor
private struct Inputs {
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
}

/// Cheap fingerprint of everything the fitted-width measurement reads, so a
/// reconcile whose width inputs are unchanged reuses the cached width instead
/// of re-running the font measurement over the names. `.auto` carries the exact
/// capped strings `measuredNames()` produces — so any rename or account-label
/// change busts it; `.manual` carries the window content width the manual path
/// returns. (`measuredNames()` itself still runs each reconcile to build the key;
/// the memo only skips the per-name `NSString` sizing.)
private enum WidthMeasurementKey: Equatable {
    case manual(width: CGFloat)
    case auto(names: [String], avatarSize: CGFloat, maxWidth: CGFloat)
}

/// Whether a measured row shows its optional second (caption) line, the only
/// per-row content that moves its height — every text element is `lineLimit(1)`,
/// so the line's *text* doesn't matter, only its presence.
private enum RowHeightSignature: Equatable {
    case header
    case contact(hasSecondLine: Bool)
    case room(hasSecondLine: Bool)
}

/// The theme terms that move row height: the avatar (its size, and whether it
/// shows at all). `showStatusMessages` is folded into each row's
/// `RowHeightSignature` second-line flag, and the 8-pt presence dot never
/// exceeds the text/avatar height, so neither belongs here. Properties are read
/// only via the synthesized `==`, which Periphery can't see.
private struct RowHeightThemeSignature: Equatable {
    // periphery:ignore
    let avatarSize: CGFloat
    // periphery:ignore
    let showAvatars: Bool
}

/// Cheap fingerprint of everything the per-row height measurement reads, so a
/// reconcile whose height inputs are unchanged reuses the cached heights instead
/// of laying out up to `maxMeasuredRows` `NSHostingView`s. Properties are read
/// only via the synthesized `==`, which Periphery can't see.
private struct HeightMeasurementKey: Equatable {
    // periphery:ignore
    let width: CGFloat
    // periphery:ignore
    let totalRowCount: Int
    // periphery:ignore
    let maxListHeight: CGFloat
    // periphery:ignore
    let rows: [RowHeightSignature]
    // periphery:ignore
    let theme: RowHeightThemeSignature
}

/// The memoized output of the per-row height measurement.
private struct MeasuredGeometry {
    let newHeights: [CGFloat]
    let listHeight: CGFloat
}

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
        coordinator.inputs = Inputs(
            environment: environment,
            theme: theme,
            openChat: openChat,
            openWindow: openWindow,
            transcriptScope: transcriptScope,
            presentSheet: presentSheet,
            preferences: preferences,
            incomingRows: rows,
            chromeHeight: chromeHeight,
            autoSizeVertical: autoSizeVertical,
            autoSizeHorizontal: autoSizeHorizontal,
            maxWidthPreference: maxWidthPreference,
            hasConnectedAccount: hasConnectedAccount
        )
        coordinator.reconcile()
    }

    /// Owns the table, the row diff, selection-to-open routing, name/height
    /// measurement, and the co-animated window-frame resize. Subclasses
    /// `NSObject` solely to adopt the AppKit table/menu delegate protocols.
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        fileprivate var inputs = Inputs()

        private var rows: [ContactListRow] = []
        private var rowHeights: [CGFloat] = []
        private var lastAppliedKey: ContactListResize.LayoutKey?
        private var pendingInitialApply = true
        private var measuringHost: NSHostingView<ContactListCellContent>?
        // Geometry memos in front of the expensive measurement: a matching key
        // means the measured output is identical, so the name scan / per-row
        // `NSHostingView` layout can be skipped. Both keys are rebuilt from live
        // service state every reconcile, so they invalidate on any input change.
        private var widthMemo: (key: WidthMeasurementKey, width: CGFloat)?
        private var heightMemo: (key: HeightMeasurementKey, geometry: MeasuredGeometry)?
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
            container.setAccessibilityValue(inputs.hasConnectedAccount ? "connected" : "connecting")

            self.container = container
            self.scrollView = scrollView
            tableView = table
            return container
        }

        // MARK: - Reconciliation

        func reconcile() {
            guard let theme = inputs.theme, inputs.environment != nil, inputs.preferences != nil,
                  let tableView, let scrollView else { return }

            container?.setAccessibilityValue(inputs.hasConnectedAccount ? "connected" : "connecting")

            // Window policy (the resize-gate axis locks) must track the auto-size
            // prefs on every pass, before the layout-key bail below: a pure
            // preference toggle doesn't change the key, so applying it only in
            // `applyLayout` would leave the gate stale until an unrelated reconcile.
            updateResizeGateLocks()

            let contentWidth = memoizedContentWidth()
            let measureCount = min(inputs.incomingRows.count, maxMeasuredRows)
            let flatRowHeight = theme.current.avatarSize + estimatedRowChrome
            let geometry = memoizedHeights(
                contentWidth: contentWidth,
                measureCount: measureCount,
                flatRowHeight: flatRowHeight
            )
            let newHeights = geometry.newHeights
            let listHeight = geometry.listHeight

            // Auto-size mode fits the window to the roster, so a scroller is only
            // needed when the roster exceeds the screen cap; keeping it off
            // otherwise avoids the overlay scroller flashing over the trailing
            // avatars while rows insert/remove during a resize. Manual mode lets
            // the user shrink the window below the roster, so the scroller must
            // stay available there.
            scrollView.hasVerticalScroller = !inputs.autoSizeVertical || listHeight >= maxListHeight

            let window = tableView.window
            let targetContentSize = targetContentSize(window: window, contentWidth: contentWidth, listHeight: listHeight)
            let scale = window?.backingScaleFactor ?? scrollView.window?.backingScaleFactor ?? 2
            let key = ContactListResize.LayoutKey(
                rowIDs: inputs.incomingRows.map(\.id),
                contentSize: targetContentSize,
                scale: scale
            )
            // A matching key means geometry is unchanged, but a value-passed
            // field (not read reactively) like a group header's online count can
            // still differ, so re-host the visible cells. `rowIDs` are part of the
            // key, so they're identical on a bail and swapping rows is safe.
            guard key != lastAppliedKey else {
                refreshPersistingCells(newRows: inputs.incomingRows)
                rows = inputs.incomingRows
                return
            }

            applyLayout(newHeights: newHeights, targetContentSize: targetContentSize, key: key, window: window, tableView: tableView)
        }

        /// Measures the AppKit terms — the title-bar inset and the window's
        /// current content size — and delegates the per-axis composition to
        /// `ContactListSizing.targetContentSize`, which owns that contract.
        private func targetContentSize(window: NSWindow?, contentWidth: CGFloat, listHeight: CGFloat) -> CGSize {
            ContactListSizing.targetContentSize(
                autoSizeHorizontal: inputs.autoSizeHorizontal,
                autoSizeVertical: inputs.autoSizeVertical,
                contentWidth: contentWidth,
                listHeight: listHeight,
                chromeHeight: inputs.chromeHeight,
                titlebarInset: titlebarInset(window),
                floorWidth: ContactListWidthMetrics.floor,
                maxWidth: clampedMaxWidth,
                currentContentSize: window.map { $0.contentRect(forFrameRect: $0.frame).size }
            )
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
            let newIDs = inputs.incomingRows.map(\.id)
            let heightsChanged = newHeights != rowHeights

            guard let window else {
                rows = inputs.incomingRows
                rowHeights = newHeights
                tableView.reloadData()
                return
            }
            lastAppliedKey = key
            installResizeGate(on: window)

            let drivesFrame = inputs.autoSizeVertical || inputs.autoSizeHorizontal
            let targetFrame: CGRect? = drivesFrame ? frame(for: targetContentSize, window: window) : nil
            let animate = !pendingInitialApply && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            pendingInitialApply = false

            guard animate else {
                rows = inputs.incomingRows
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
            refreshPersistingCells(newRows: inputs.incomingRows)
            rows = inputs.incomingRows
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

        /// Syncs the resize gate's per-axis veto with the current auto-size prefs.
        private func updateResizeGateLocks() {
            resizeGate.lockWidth = inputs.autoSizeHorizontal
            resizeGate.lockHeight = inputs.autoSizeVertical
        }

        /// Installs the window-delegate proxy that vetoes user resize on the
        /// auto-size axes. SwiftUI re-asserts `.resizable` / `contentMaxSize` /
        /// `styleMask`, so `windowWillResize` is the only hook that holds; the
        /// proxy forwards every other delegate message to SwiftUI's delegate. The
        /// axis locks themselves are kept current by `updateResizeGateLocks`.
        private func installResizeGate(on window: NSWindow) {
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
            CGFloat(ContactListSizing.clampMaxWidth(inputs.maxWidthPreference))
        }

        private var maxListHeight: CGFloat {
            (NSScreen.main?.visibleFrame.height ?? 800) - 160
        }

        /// Content width the rows render at, memoized: the auto-fit width when
        /// horizontal auto-size is on, otherwise the window's current content
        /// width (the coordinator never drives a manual axis). The capped name
        /// scan runs each reconcile to build the key; on a match the per-name font
        /// measurement and fitted-width calc are what's skipped.
        private func memoizedContentWidth() -> CGFloat {
            let key: WidthMeasurementKey = inputs.autoSizeHorizontal
                ? .auto(names: measuredNames(), avatarSize: inputs.theme?.current.avatarSize ?? 0, maxWidth: clampedMaxWidth)
                : .manual(width: manualContentWidth())
            if let widthMemo, widthMemo.key == key { return widthMemo.width }
            let width: CGFloat = switch key {
            case let .auto(names, avatarSize, maxWidth): fittedContentWidth(names: names, avatarSize: avatarSize, maxWidth: maxWidth)
            case let .manual(width): width
            }
            widthMemo = (key, width)
            return width
        }

        private func manualContentWidth() -> CGFloat {
            if let window = tableView?.window {
                return window.contentRect(forFrameRect: window.frame).width
            }
            return scrollView?.bounds.width ?? ContactListWidthMetrics.floor
        }

        /// The capped contact/room names the fitted-width scan measures, in row
        /// order: each contact's display name plus its account-disambiguation
        /// label, each room's title; headers skipped. Capped so a pathological
        /// roster can't drive unbounded measurement. Shared with the width memo
        /// key so the cache invalidates on exactly the renames and account-label
        /// changes that move the fitted width.
        private func measuredNames() -> [String] {
            guard let environment = inputs.environment else { return [] }
            var names: [String] = []
            for row in inputs.incomingRows where names.count < maxMeasuredNames {
                let name: String? = switch row {
                case .header:
                    nil
                case let .contact(_, contact):
                    measuringName(for: contact, environment: environment)
                case let .room(room):
                    room.displayTitle
                }
                guard let name else { continue }
                names.append(String(name.prefix(maxMeasuredNameLength)))
            }
            return names
        }

        /// Fits the window width to the widest measured name, via the row font.
        /// `avatarSize` and `maxWidth` come from the memo key so the cached width
        /// and the key that gates it are computed from identical inputs.
        private func fittedContentWidth(names: [String], avatarSize: CGFloat, maxWidth: CGFloat) -> CGFloat {
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let maxNameWidth = names.reduce(CGFloat(0)) { max($0, ($1 as NSString).size(withAttributes: attributes).width) }
            return CGFloat(ContactListSizing.fittedWidth(
                maxNameWidth: Double(maxNameWidth),
                avatarSize: Double(avatarSize),
                rowChrome: Double(ContactListWidthMetrics.rowChrome),
                floorWidth: Double(ContactListWidthMetrics.floor),
                maxWidth: Double(maxWidth)
            ))
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

        /// The per-row heights and the auto-sized list height, memoized: on a key
        /// match the per-row `NSHostingView` layout loop is skipped.
        private func memoizedHeights(contentWidth: CGFloat, measureCount: Int, flatRowHeight: CGFloat) -> MeasuredGeometry {
            let key = HeightMeasurementKey(
                width: contentWidth,
                totalRowCount: inputs.incomingRows.count,
                maxListHeight: maxListHeight,
                rows: (0 ..< measureCount).map { rowHeightSignature(for: inputs.incomingRows[$0]) },
                theme: themeHeightSignature()
            )
            if let heightMemo, heightMemo.key == key { return heightMemo.geometry }
            let measuredHeights = (0 ..< measureCount).map { measureHeight(for: inputs.incomingRows[$0], width: contentWidth) }
            let newHeights = (0 ..< inputs.incomingRows.count).map { $0 < measureCount ? measuredHeights[$0] : flatRowHeight }
            let listHeight = targetListHeight(
                measuredHeights: measuredHeights,
                totalRowCount: inputs.incomingRows.count,
                flatRowHeight: flatRowHeight
            )
            let geometry = MeasuredGeometry(newHeights: newHeights, listHeight: listHeight)
            heightMemo = (key, geometry)
            return geometry
        }

        /// The layout-affecting fingerprint of one row: its kind, and for the two
        /// kinds with an optional caption line, whether that line shows. Derives
        /// `hasSecondLine` from the same `ContactCaption`/`RoomCaption` resolvers
        /// the row views render from, so the memo predicts the 1- vs 2-line height
        /// without hosting the view and can't drift from what renders.
        private func rowHeightSignature(for row: ContactListRow) -> RowHeightSignature {
            switch row {
            case .header:
                return .header
            case let .contact(_, contact):
                return .contact(hasSecondLine: contactHasSecondLine(contact))
            case let .room(room):
                return .room(hasSecondLine: roomHasSecondLine(room))
            }
        }

        private func contactHasSecondLine(_ contact: Contact) -> Bool {
            guard let environment = inputs.environment, let theme = inputs.theme else { return false }
            return ContactCaption.resolve(
                for: contact,
                showStatusMessages: theme.current.showStatusMessages,
                presenceService: environment.presenceService
            ).hasSecondLine
        }

        private func roomHasSecondLine(_ room: Conversation) -> Bool {
            guard let environment = inputs.environment else { return false }
            return RoomCaption.resolve(for: room, chatService: environment.chatService).hasSecondLine
        }

        private func themeHeightSignature() -> RowHeightThemeSignature {
            let theme = inputs.theme?.current
            return RowHeightThemeSignature(
                avatarSize: theme?.avatarSize ?? 0,
                showAvatars: theme?.showAvatars ?? false
            )
        }

        /// Self-sized height of one row at the target content width, via a
        /// reused off-screen `NSHostingView`.
        private func measureHeight(for row: ContactListRow, width: CGFloat) -> CGFloat {
            guard let content = cellContent(for: row) else {
                return (inputs.theme?.current.avatarSize ?? 40) + estimatedRowChrome
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
            guard let environment = inputs.environment, let theme = inputs.theme else { return nil }
            return ContactListCellContent(
                row: row,
                environment: environment,
                theme: theme,
                openChat: inputs.openChat,
                toggle: { [weak self] sectionKey in self?.inputs.preferences?.toggleGroupExpanded(sectionKey) },
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
            inputs.openChat(key.jid, accountID: key.accountID)
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
            guard rows.indices.contains(index), let environment = inputs.environment else { return nil }
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
                self?.inputs.openChat(contact.jid.description, accountID: contact.accountID)
            })
            menu.addItem(item("Get Info", identifier: "contact-context-get-info") { [weak self] in
                self?.inputs.openWindow?(id: "contact-info", value: ContactInfoRef(accountID: contact.accountID, jid: contact.jid.description))
            })
            menu.addItem(item("History", identifier: "contact-context-history") { [weak self] in
                let ref = conversation.map { ConversationRef(conversation: $0) }
                    ?? ConversationRef(accountID: contact.accountID, jid: contact.jid.description, type: .chat)
                self?.inputs.transcriptScope?.request(ref)
                self?.inputs.openWindow?(id: "transcripts")
            })
            menu.addItem(.separator())
            if let conversation {
                for menuItem in pinMuteItems(for: conversation, accountID: contact.accountID, environment: environment) {
                    menu.addItem(menuItem)
                }
                menu.addItem(.separator())
            }
            menu.addItem(item("Rename…") { [weak self] in
                self?.inputs.presentSheet(.rename(contact))
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
                self?.inputs.openChat(conversation.jid.description, accountID: conversation.accountID)
            })
            guard let accountID = conversation.accountID else { return menu }
            menu.addItem(.separator())
            for menuItem in pinMuteItems(for: conversation, accountID: accountID, environment: environment) {
                menu.addItem(menuItem)
            }
            menu.addItem(.separator())
            menu.addItem(item("Invite User…") { [weak self] in
                self?.inputs.presentSheet(.invite(conversation))
            })
            if canManageRoom(conversation, accountID: accountID, environment: environment) {
                menu.addItem(.separator())
                menu.addItem(item("Room Settings…", identifier: "room-settings-menu-item") { [weak self] in
                    self?.inputs.presentSheet(.roomSettings(conversation))
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
            rowHeights.indices.contains(row) ? rowHeights[row] : (inputs.theme?.current.avatarSize ?? 40) + estimatedRowChrome
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

    /// Keep the edge resize affordance in sync with the axis locks. When both
    /// axes are locked, suppress the misleading resize cursor: SwiftUI keeps
    /// re-adding `.resizable` (a one-time removal doesn't hold), so re-remove it
    /// whenever it reappears (`windowWillResize` already vetoes the drag, and
    /// programmatic `setFrame` works without `.resizable`). Otherwise restore
    /// `.resizable` if it's missing, so unlocking an axis at runtime brings the
    /// handle back immediately rather than waiting for SwiftUI's next re-assert.
    /// Mixed auto/manual modes keep `.resizable` and rely on the per-axis veto.
    func windowDidUpdate(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if lockWidth, lockHeight {
            if window.styleMask.contains(.resizable) { window.styleMask.remove(.resizable) }
        } else if !window.styleMask.contains(.resizable) {
            window.styleMask.insert(.resizable)
        }
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
