import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import Logging

private let log = Logger(label: "im.ducko.integrationtests.ui")

/// Drives the packaged `Ducko.app` bundle as a child process and exposes
/// identifier-keyed accessibility queries to UI integration tests.
///
/// Mirrors `CLIProcess`: the actor owns the launched-app handle, an env
/// dictionary, and two LIFO cleanup queues (one that runs while the app is
/// still alive, one that runs after exit). All public methods are
/// identifier-keyed so the non-Sendable `AXUIElement` handles never cross the
/// actor boundary; each call walks the AX tree from the application root and
/// reacquires its element, which also avoids stale handles after a SwiftUI
/// view refresh.
actor AppAccessor {
    /// Boot marker the launch helper waits for.
    enum LaunchTarget {
        /// Fresh `DUCKO_PROFILE` — the welcome screen renders the
        /// `setup-mode-picker`.
        case welcome
        /// Pre-seeded profile — the contact list auto-connects and renders.
        case contactList
    }

    /// Cleanup-action ordering bucket.
    enum CleanupPhase {
        /// Runs before `process.terminate()` so the action can drive UI
        /// (e.g. reset presence, leave a room).
        case inApp
        /// Runs after the app exits (e.g. profile-directory removal).
        case postExit
    }

    nonisolated let profile: String
    nonisolated let environment: [String: String]

    /// `NSRunningApplication` instead of Foundation `Process` so the spawn
    /// goes through LaunchServices (`NSWorkspace.openApplication`). Direct
    /// `Process.run()` on `Ducko.app/Contents/MacOS/DuckoApp` produces a
    /// process that authenticates and loads the roster but never registers
    /// any visible NSWindow with the WindowServer — `CGWindowList` returns
    /// zero windows for the PID, the AX walker never finds `contact-list`,
    /// and every UI test times out at the launch barrier. LaunchServices
    /// performs the missing GUI registration so `kAXIdentifierAttribute`
    /// lookups succeed.
    private var process: NSRunningApplication?
    private var inAppCleanupActions: [@Sendable () async -> Void] = []
    private var postExitCleanupActions: [@Sendable () async -> Void] = []

    init(profile: String) {
        self.profile = profile

        // Mirror CLIProcess's environment allowlist: only the keys the app
        // needs to find Foundation bundles, locales, and the user's home
        // directory. Importantly we never inherit DUCKO_USE_KEYCHAIN, so a
        // stray "1" in the developer's shell cannot route test passwords
        // into the real macOS Keychain.
        let parent = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "DUCKO_PROFILE": profile
        ]
        for key in ["HOME", "PATH", "LANG", "LC_ALL"] {
            if let value = parent[key] {
                env[key] = value
            }
        }
        self.environment = env
    }

    // MARK: - Bundle resolution

    /// Path to the packaged `Ducko.app` bundle. Resolved relative to this
    /// file via `#filePath`; mirrors `CLIProcess.binaryPath`'s walk-up.
    /// Canonical input to `NSWorkspace.openApplication` and to
    /// `assertDebugBundle`'s `Info.plist` lookup.
    static var appBundleURL: URL {
        // AppAccessor.swift lives at:
        //   IntegrationTests/Tests/DuckoIntegrationTests/UI/AppAccessor.swift
        // The packaged app bundle lives at:
        //   <repo>/Ducko.app/
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // UI
            .deletingLastPathComponent() // DuckoIntegrationTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // IntegrationTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Ducko.app")
    }

    /// Path to the inner executable inside `appBundleURL`. Used only for the
    /// existence-on-disk skip predicate; `NSWorkspace.openApplication` takes
    /// the bundle URL directly.
    static var executableURL: URL {
        appBundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent("DuckoApp")
    }

    /// Per-test skip predicate — UI tests need a packaged `.app` on disk.
    static var appBundleExists: Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    /// Per-test skip predicate — UI tests need Accessibility trust granted.
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Lifecycle

    /// Runs `body` with a fresh `AppAccessor`, awaiting cleanup on both
    /// success and failure paths. Mirrors `CLIProcess.withProcess`.
    static func withAppAccessor<T: Sendable>(
        profile: String? = nil,
        target: LaunchTarget = .contactList,
        _ body: sending (AppAccessor) async throws -> T
    ) async throws -> T {
        let resolvedProfile = profile ?? "inttest-ui-\(UUID().uuidString.prefix(8))"
        let accessor = AppAccessor(profile: resolvedProfile)
        do {
            try await accessor.launch(target: target)
            let result = try await body(accessor)
            await accessor.terminate()
            return result
        } catch {
            await accessor.terminate()
            throw error
        }
    }

    /// Spawns the packaged app, activates it, and waits for the boot marker
    /// matching `target`. Throws and rolls back the partial spawn if the
    /// boot wait fails.
    func launch(target: LaunchTarget) async throws {
        // Register the profile-directory reap FIRST so it survives a thrown
        // precondition check below. `UISeededApp.withSeededApp` writes
        // plaintext credentials to `Ducko-Dev-<profile>/credentials.json`
        // before calling launch — if `assertDebugBundle` (or any other
        // pre-launch guard) throws, those creds would otherwise leak on
        // disk. `CLIProcess.removeProfileDirectory` is idempotent
        // (`fileNoSuchFile` is swallowed) so registering early is safe even
        // when the harness exits before any directory is created.
        let profileForCleanup = profile
        postExitCleanupActions.append {
            await CLIProcess.removeProfileDirectory(profile: profileForCleanup)
        }

        let bundleURL = Self.appBundleURL
        guard FileManager.default.isExecutableFile(atPath: Self.executableURL.path) else {
            throw TestHarnessError.appBundleMissing(path: Self.executableURL.path)
        }
        guard AXIsProcessTrusted() else {
            throw TestHarnessError.axTrustMissing
        }

        // Refuse to launch a release-built bundle. A release build ignores
        // `DUCKO_PROFILE`, persists creds in the real Keychain, and stores
        // transcripts under `~/Library/Application Support/Ducko/` — typing
        // test passwords into it would pollute the developer's production
        // app data. `Scripts/package_app.sh` writes the build configuration
        // into Info.plist's `DuckoBuildConfiguration` key (`debug` vs
        // `release`); we read it pre-launch so the gate fires before any
        // process spawns or any input is dispatched.
        try Self.assertDebugBundle(at: bundleURL)

        // Argument-domain UserDefaults override: `NSUserDefaults` reads
        // `-key value` pairs from process arguments and treats them as the
        // highest-priority domain on read. NSWindow's `setFrameAutosaveName`
        // consults `standardUserDefaults`, so this override wins over the
        // persisted frame in `~/Library/Preferences/im.ducko.plist` for this
        // launch only — the developer's saved Contacts position is never
        // read or written.
        //
        // The Contacts window's `.defaultSize(width: 280, height: 600)` is
        // too narrow for all six toolbar items + `.searchable` field to lay
        // out without AppKit collapsing one into the `>>` overflow popup,
        // where `kAXIdentifierAttribute` lookups (e.g. `join-room-toolbar-
        // button`) miss. 720pt gives every item room to render.
        //
        // Each pair is two argv elements (`"-<key>"`, `"<value>"`); a
        // contributor adding a second pair must keep that one-element-per-
        // token shape, otherwise the next `-` token is consumed as the
        // previous value and silently swallowed.
        let runningApp = try await Self.openApp(
            at: bundleURL,
            environment: environment,
            arguments: ["-NSWindow Frame contacts", "0 100 720 600 0 0 2560 1410"]
        )
        process = runningApp

        // Activate Ducko so subsequent .cghidEventTap keystrokes route to it
        // rather than the test runner / Terminal / Xcode.
        await Self.activateApp(pid: runningApp.processIdentifier)

        // Bound every AX read against a hung child. The timeout is per-AX-
        // object and does not transfer to equal elements created later, so
        // we set it on the system-wide accessibility object — that establishes
        // a process-wide default that subsequent `AXUIElementCreateApplication`
        // calls inherit.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2.0)

        do {
            switch target {
            case .welcome:
                try await waitForElement(identifier: "setup-mode-picker", timeout: TestTimeout.connect)
            case .contactList:
                try await waitForElement(identifier: "contact-list", timeout: TestTimeout.connect)
            }
        } catch {
            await terminate()
            throw error
        }
    }

    /// Appends a cleanup action; actions in each phase queue run in reverse
    /// order during teardown. **In-app cleanup is best-effort**: the closure
    /// signature is non-throwing, so callers must wrap UI-driving AX calls
    /// in `try?` and never propagate errors from the cleanup body — the test
    /// body's original error is what the suite needs to surface.
    func addCleanup(_ action: @escaping @Sendable () async -> Void, phase: CleanupPhase = .inApp) {
        switch phase {
        case .inApp:
            inAppCleanupActions.append(action)
        case .postExit:
            postExitCleanupActions.append(action)
        }
    }

    /// Runs in-app cleanup, terminates the launched app, then runs post-exit
    /// cleanup. Each cleanup action is bounded by a 5-second soft deadline
    /// so a hung UI cannot block teardown.
    func terminate() async {
        for action in inAppCleanupActions.reversed() {
            await runIntegrationCleanup(action, timeout: .seconds(5), label: "UI in-app")
        }
        inAppCleanupActions.removeAll()

        if let app = process, !app.isTerminated {
            app.terminate()
            let exited = await Self.waitForRunningAppExit(app, timeout: .seconds(2))
            if !exited {
                app.forceTerminate()
                _ = await Self.waitForRunningAppExit(app, timeout: .seconds(2))
            }
        }
        process = nil

        for action in postExitCleanupActions.reversed() {
            await runIntegrationCleanup(action, timeout: .seconds(5), label: "UI post-exit")
        }
        postExitCleanupActions.removeAll()
    }

    // MARK: - AX queries

    /// Polls the AX tree for `identifier` until it appears or the timeout
    /// elapses. Catches only `elementNotFound` inside the predicate so an
    /// `axTrustMissing` raised by `resolveElement` is not silently relabelled
    /// as a generic timeout.
    func waitForElement(identifier: String, timeout: Duration = TestTimeout.uiElement) async throws {
        do {
            try await pollUntil(timeout: timeout) {
                do {
                    _ = try self.resolveElement(identifier: identifier)
                    return true
                } catch TestHarnessError.elementNotFound {
                    return false
                }
            }
        } catch TestHarnessError.timeout {
            // Identifiers may embed JIDs (e.g. `contact-row-bob@…`) and the
            // project privacy policy bars JIDs at warning/info/notice — log at
            // debug instead so the diagnostic is available in trace mode without
            // leaking sensitive data at higher levels.
            log.debug("waitForElement timeout (\(timeout)) for identifier '\(identifier)'")
            throw TestHarnessError.timeout
        }
    }

    /// Polls `containsDescendant(role:withSubstring:underIdentifier:)` until
    /// it returns `true` or the timeout elapses. Use this when asserting on
    /// AX state that is updated asynchronously (message bubble after
    /// `pressReturn`, room participants after a join, etc.).
    func waitForDescendant(
        role: String,
        withSubstring substring: String,
        underIdentifier identifier: String,
        timeout: Duration = TestTimeout.uiElement
    ) async throws {
        do {
            try await pollUntil(timeout: timeout) {
                try await self.containsDescendant(role: role, withSubstring: substring, underIdentifier: identifier)
            }
        } catch TestHarnessError.timeout {
            log.debug("waitForDescendant timeout (\(timeout)) role '\(role)' substring '\(substring)' under '\(identifier)'")
            throw TestHarnessError.timeout
        }
    }

    /// Polls until `identifier` is no longer present or the timeout elapses.
    /// Use this to assert dismissal of transient UI state like the typing
    /// indicator without accepting "still visible" as passing.
    func waitForAbsence(identifier: String, timeout: Duration = TestTimeout.uiElement) async throws {
        do {
            try await pollUntil(timeout: timeout) {
                do {
                    _ = try self.resolveElement(identifier: identifier)
                    return false
                } catch TestHarnessError.elementNotFound {
                    return true
                }
            }
        } catch TestHarnessError.timeout {
            log.debug("waitForAbsence timeout (\(timeout)) for identifier '\(identifier)'")
            throw TestHarnessError.timeout
        }
    }

    func click(identifier: String) async throws {
        let element = try resolveElement(identifier: identifier)
        try perform(action: kAXPressAction, on: element, identifier: identifier)
    }

    func rightClick(identifier: String) async throws {
        let element = try resolveElement(identifier: identifier)
        try perform(action: kAXShowMenuAction, on: element, identifier: identifier)
    }

    /// Synthesizes a SwiftUI-style double-click via two `CGEvent` click
    /// pairs at the element center. Two consecutive `kAXPressAction`s do
    /// NOT synthesize `.onTapGesture(count: 2)`, so this is the only path
    /// that wakes up double-tap recognizers like `ContactRow`.
    func doubleClick(identifier: String) async throws {
        let element = try resolveElement(identifier: identifier)
        guard let pid = process?.processIdentifier else {
            throw TestHarnessError.elementNotFound(identifier: identifier)
        }
        await Self.activateApp(pid: pid)

        guard let center = elementCenter(of: element) else {
            throw TestHarnessError.elementNotFound(identifier: identifier)
        }
        for clickState in [Int64(1), Int64(2)] {
            postClickPair(at: center, clickState: clickState)
        }
    }

    /// Resolves `identifier`, focuses it, and either sets `kAXValueAttribute`
    /// or falls back to per-character keystrokes. The fallback covers
    /// SwiftUI `TextField`s that ignore `kAXSetValueAction`.
    func type(_ text: String, intoIdentifier identifier: String) async throws {
        let element = try resolveElement(identifier: identifier)
        Self.setFocused(element, identifier: identifier)
        let setErr = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        if setErr == .success {
            return
        }
        if let pid = process?.processIdentifier {
            await Self.activateApp(pid: pid)
        }
        Self.synthesizeKeystrokes(for: text)
    }

    /// Search-field-aware variant: tries the kebab identifier first, then
    /// falls back to walking the application's `kAXToolbarRole` for any
    /// `kAXTextFieldRole` descendant. Ships unconditionally so callers do
    /// not branch on whether `.searchable` propagated the audit identifier.
    func type(_ text: String, intoSearchField identifier: String?) async throws {
        if let identifier {
            do {
                try await type(text, intoIdentifier: identifier)
                return
            } catch TestHarnessError.elementNotFound {
                // fall through to role-based traversal
            }
        }
        guard let pid = process?.processIdentifier else {
            throw TestHarnessError.elementNotFound(identifier: identifier ?? "search-contacts")
        }
        let appElement = AXUIElementCreateApplication(pid)
        guard let toolbar = findDescendant(in: appElement, role: kAXToolbarRole, where: { _ in true }),
              let field = findDescendant(in: toolbar, role: kAXTextFieldRole, where: { _ in true }) else {
            throw TestHarnessError.elementNotFound(identifier: identifier ?? "search-contacts")
        }
        Self.setFocused(field, identifier: identifier ?? "search-contacts")
        let setErr = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString)
        if setErr == .success {
            return
        }
        await Self.activateApp(pid: pid)
        Self.synthesizeKeystrokes(for: text)
    }

    /// Prefers `kAXConfirmAction`, falls back to a synthesized Return key
    /// for controls that don't expose Confirm.
    func pressReturn(intoIdentifier identifier: String) async throws {
        let element = try resolveElement(identifier: identifier)
        Self.setFocused(element, identifier: identifier)
        let confirmErr = AXUIElementPerformAction(element, kAXConfirmAction as CFString)
        if confirmErr == .success {
            return
        }
        try await pressKey(CGKeyCode(kVK_Return), modifiers: [])
    }

    /// Resolves `identifier` and reads `kAXValueAttribute` (falling back to
    /// `kAXTitleAttribute`). Retries once after a 50 ms sleep on a transient
    /// re-render error so callers do not need their own retry wrapper.
    func value(identifier: String) async throws -> String? {
        do {
            return try readValue(identifier: identifier)
        } catch TestHarnessError.elementNotFound {
            try await Task.sleep(for: .milliseconds(50))
            return try readValue(identifier: identifier)
        }
    }

    /// Walks `identifier`'s subtree for an element of `role` whose value or
    /// title contains `substring`. Returns `true` on first match.
    func containsDescendant(
        role: String,
        withSubstring substring: String,
        underIdentifier identifier: String
    ) async throws -> Bool {
        let container = try resolveElement(identifier: identifier)
        let match = findDescendant(in: container, role: role) { element in
            var value: AnyObject?
            var err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
            if err != .success || (value as? String) == nil {
                err = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
            }
            guard err == .success, let stringValue = value as? String else { return false }
            return stringValue.contains(substring)
        }
        return match != nil
    }

    /// Resolves `identifier` as a segmented picker / button group and clicks
    /// the segment whose label matches `title`. Reads `kAXTitleAttribute`
    /// first and falls back to `kAXDescriptionAttribute` — SwiftUI's
    /// `Picker(.segmented)` on macOS 26 publishes the segment label only via
    /// the description attribute, with title returning `missing value`.
    func clickSegment(title: String, identifier: String) async throws {
        let picker = try resolveElement(identifier: identifier)
        let match = findDescendant(
            in: picker,
            roles: [kAXRadioButtonRole, kAXButtonRole],
            where: { candidate in segmentLabel(of: candidate) == title }
        )
        guard let segment = match else {
            throw TestHarnessError.elementNotFound(identifier: "\(identifier)/segment[\(title)]")
        }
        try perform(action: kAXPressAction, on: segment, identifier: identifier)
    }

    /// Resolves `identifier`, normalizes to the nearest `kAXTabGroupRole`
    /// element, and presses the tab whose label matches `title`. NSTabView
    /// exposes its tab buttons via the dedicated `kAXTabsAttribute` rather
    /// than `kAXChildrenAttribute`, so the tabs are not reachable via the
    /// recursive descendant walker that powers the rest of the harness.
    /// SwiftUI's `.accessibilityIdentifier` on a `TabView` may also attach
    /// to the focused content pane rather than the kAXTabGroupRole parent;
    /// the ancestor walk handles that case.
    func clickTab(title: String, identifier: String) async throws {
        let resolved = try resolveElement(identifier: identifier)
        let tabGroup = elementRole(of: resolved) == kAXTabGroupRole
            ? resolved
            : findDescendant(in: resolved, role: kAXTabGroupRole, where: { _ in true })
            ?? findAncestor(from: resolved, role: kAXTabGroupRole)
        guard let tabGroup else {
            throw TestHarnessError.elementNotFound(identifier: "\(identifier)/tabGroup")
        }
        var tabsValue: AnyObject?
        let err = AXUIElementCopyAttributeValue(tabGroup, kAXTabsAttribute as CFString, &tabsValue)
        guard err == .success, let tabs = tabsValue as? [AXUIElement] else {
            throw TestHarnessError.elementNotFound(identifier: "\(identifier)/tab[\(title)]")
        }
        guard let tab = tabs.first(where: { segmentLabel(of: $0) == title }) else {
            throw TestHarnessError.elementNotFound(identifier: "\(identifier)/tab[\(title)]")
        }
        try perform(action: kAXPressAction, on: tab, identifier: "\(identifier)/tab[\(title)]")
    }

    /// Reads the human-visible label of a segmented-picker / tab segment.
    /// Tries `kAXTitleAttribute` then `kAXDescriptionAttribute` because
    /// SwiftUI's segmented `Picker` on macOS 26 publishes the label via
    /// description while title is `missing value`.
    private func segmentLabel(of element: AXUIElement) -> String? {
        var value: AnyObject?
        var err = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        if err != .success || (value as? String)?.isEmpty ?? true {
            err = AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &value)
        }
        guard err == .success else { return nil }
        return value as? String
    }

    func clickMenuItem(title: String) async throws {
        guard let pid = process?.processIdentifier else {
            throw TestHarnessError.elementNotFound(identifier: "menu-item[\(title)]")
        }
        let appElement = AXUIElementCreateApplication(pid)
        guard let menuItem = findMenuItem(in: appElement, title: title) else {
            throw TestHarnessError.elementNotFound(identifier: "menu-item[\(title)]")
        }
        try perform(action: kAXPressAction, on: menuItem, identifier: "menu-item[\(title)]")
    }

    /// Selects a menu item inside an NSPopUpButton-backed control (e.g.
    /// SwiftUI `Picker(.menu)`) by title and commits the popup's selection.
    ///
    /// Distinct from `clickMenuItem(title:)`: that helper is for menu-bar /
    /// context-menu items reachable from the application AX root and uses
    /// `kAXPressAction` (press semantics, `NSAccessibility.Action.press`).
    /// Popup pickers need `kAXPickAction` (pick semantics,
    /// `NSAccessibility.Action.pick` / `accessibilityPerformPick()`) — pressing
    /// a menu item inside a popup highlights/expands it without committing the
    /// popup's value on macOS 26, leaving the SwiftUI `Binding(set:)` setter
    /// unfired and `kAXValueAttribute` stale.
    ///
    /// Per Apple's `AXUIElementPerformAction` docs, `kAXErrorCannotComplete`
    /// during modal callbacks (which menu tracking is) does NOT necessarily
    /// indicate failure — the action may have taken effect anyway. So we poll
    /// for the menu becoming visible after `kAXShowMenuAction`, and for the
    /// popup value reconciling after `kAXPickAction`, before falling back to
    /// alternative input synthesis.
    func pickPopUpItem(title: String, identifier: String) async throws {
        let popUp = try resolveElement(identifier: identifier)
        if let pid = process?.processIdentifier {
            await Self.activateApp(pid: pid)
        }

        // Open the menu — show-menu first; press fallback only if the menu
        // doesn't appear (covers controls that don't expose show-menu and the
        // documented-indeterminate `cannotComplete` case where show-menu may
        // have actually opened the menu). Use a short poll for the
        // speculative show-menu probe (in practice menus publish in 100ms or
        // not at all) so the press fallback isn't held up for the full UI
        // timeout when show-menu silently no-ops.
        let showErr = AXUIElementPerformAction(popUp, kAXShowMenuAction as CFString)
        if showErr == .apiDisabled { throw TestHarnessError.axTrustMissing }
        do {
            try await waitForShownMenu(on: popUp, identifier: identifier, timeout: .milliseconds(500))
        } catch TestHarnessError.timeout {
            try perform(action: kAXPressAction, on: popUp, identifier: identifier)
            try await waitForShownMenu(on: popUp, identifier: identifier)
        }

        // Once the menu is open, an error escaping this function would leave
        // it open and eating events for subsequent helpers. Track commit state
        // and post Escape on the failure path. The committed state is
        // determined by the popup's value matching `title`, not by the AX
        // action's return code, because `cannotComplete` is indeterminate.
        var commitAttempted = false
        do {
            let menu = try resolveShownMenu(for: popUp, identifier: identifier)
            guard let item = findMenuItem(in: menu, title: title) else {
                throw TestHarnessError.elementNotFound(identifier: "\(identifier)/menu-item[\(title)]")
            }

            // kAXPickAction is the canonical "select this menu item" action.
            // Always poll the popup value afterward — `cannotComplete` may
            // have committed the pick anyway; fall back to a synthesized
            // CGEvent click pair only if the value never reconciles.
            let pickErr = AXUIElementPerformAction(item, kAXPickAction as CFString)
            if pickErr == .apiDisabled { throw TestHarnessError.axTrustMissing }
            do {
                try await waitForValue(title, identifier: identifier)
                commitAttempted = true
            } catch TestHarnessError.timeout {
                guard let center = elementCenter(of: item) else {
                    throw TestHarnessError.elementNotFound(identifier: "\(identifier)/menu-item[\(title)]")
                }
                postClickPair(at: center, clickState: 1)
                commitAttempted = true
                do {
                    try await waitForValue(title, identifier: identifier)
                } catch TestHarnessError.timeout {
                    log.debug("pickPopUpItem timeout (\(TestTimeout.uiElement)) for identifier '\(identifier)' title '\(title)'")
                    throw TestHarnessError.timeout
                }
            }
        } catch {
            if !commitAttempted {
                try? await pressKey(CGKeyCode(kVK_Escape), modifiers: [])
            }
            throw error
        }
    }

    /// Synthesizes a key-down/up event pair via `.cghidEventTap`. Re-
    /// activates Ducko first so the test runner cannot drift to the front
    /// between calls.
    func pressKey(_ key: CGKeyCode, modifiers: CGEventFlags) async throws {
        if let pid = process?.processIdentifier {
            await Self.activateApp(pid: pid)
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return }
        down.flags = modifiers
        up.flags = modifiers
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Convenience for the right-click → menu-item pattern: waits for the
    /// menu-item identifier to appear, then clicks it.
    func contextMenuItem(identifier: String) async throws {
        try await waitForElement(identifier: identifier, timeout: TestTimeout.uiElement)
        try await click(identifier: identifier)
    }

    /// Activates Ducko, raises the named window, makes it main, and points
    /// the application's `kAXFocusedWindowAttribute` at it. Used to bring a
    /// non-key window forward before clicking buttons on a sheet attached
    /// to it.
    func activateWindow(named title: String) async throws {
        guard let pid = process?.processIdentifier else {
            throw TestHarnessError.elementNotFound(identifier: "window[\(title)]")
        }
        await Self.activateApp(pid: pid)
        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: AnyObject?
        let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        guard err == .success, let windows = windowsValue as? [AXUIElement] else {
            throw TestHarnessError.elementNotFound(identifier: "window[\(title)]")
        }
        for window in windows {
            var titleValue: AnyObject?
            let titleErr = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
            guard titleErr == .success, let windowTitle = titleValue as? String else { continue }
            if windowTitle == title || windowTitle.contains(title) {
                // Translate every non-success result. A silent .cannotComplete /
                // .invalidUIElement on raise/main/focused-window leaves the
                // wrong window key, and downstream sheet-button clicks would
                // fail with a misleading "elementNotFound" rather than a
                // clear AX-routing diagnostic.
                let raiseErr = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                try mapWindowError(raiseErr, title: title)
                let mainErr = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                try mapWindowError(mainErr, title: title)
                let focusedErr = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
                try mapWindowError(focusedErr, title: title)
                return
            }
        }
        throw TestHarnessError.elementNotFound(identifier: "window[\(title)]")
    }

    /// Walks `identifier`'s subtree post-order DFS and returns the
    /// last-encountered `kAXIdentifierAttribute` value that starts with
    /// `prefix`. Used by `testMessageCorrection` to discover the just-sent
    /// bubble's id without an opaque "deepest descendant" walk.
    func lastIdentifier(matchingPrefix prefix: String, underIdentifier identifier: String) async throws -> String? {
        do {
            return try collectLastIdentifier(matchingPrefix: prefix, under: identifier)
        } catch TestHarnessError.elementNotFound {
            try await Task.sleep(for: .milliseconds(50))
            return try collectLastIdentifier(matchingPrefix: prefix, under: identifier)
        }
    }

    // MARK: - Internal AX helpers

    /// Loops `check` every 50 ms until it returns `true` or `timeout` elapses.
    /// One final probe runs after the deadline so a `check` invocation that
    /// started just before the deadline (and was still in flight as it
    /// crossed) gets a chance to surface a result before timing out. Callers
    /// that need a per-call diagnostic on timeout catch
    /// `TestHarnessError.timeout` and log before re-throwing.
    private func pollUntil(timeout: Duration, check: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        if try await check() { return }
        throw TestHarnessError.timeout
    }

    private func readValue(identifier: String) throws -> String? {
        let element = try resolveElement(identifier: identifier)
        var value: AnyObject?
        var err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        if err == .attributeUnsupported || err == .noValue {
            err = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        }
        if err == .success {
            return value as? String
        }
        if err == .apiDisabled {
            throw TestHarnessError.axTrustMissing
        }
        throw TestHarnessError.elementNotFound(identifier: identifier)
    }

    private func collectLastIdentifier(matchingPrefix prefix: String, under identifier: String) throws -> String? {
        let container = try resolveElement(identifier: identifier)
        var matches: [String] = []
        collectIdentifiers(in: container, matchingPrefix: prefix, into: &matches)
        return matches.last
    }

    private func resolveElement(identifier: String) throws -> AXUIElement {
        guard let pid = process?.processIdentifier else {
            throw TestHarnessError.elementNotFound(identifier: identifier)
        }
        let appElement = AXUIElementCreateApplication(pid)
        if let element = findDescendant(in: appElement, where: { element in
            var value: AnyObject?
            let err = AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &value)
            return err == .success && (value as? String) == identifier
        }) {
            return element
        }
        // Distinguish "AX disabled" from "not found" by re-probing the root.
        var probeValue: AnyObject?
        let probe = AXUIElementCopyAttributeValue(appElement, kAXRoleAttribute as CFString, &probeValue)
        if probe == .apiDisabled {
            throw TestHarnessError.axTrustMissing
        }
        throw TestHarnessError.elementNotFound(identifier: identifier)
    }

    private func perform(action: String, on element: AXUIElement, identifier: String) throws {
        let err = AXUIElementPerformAction(element, action as CFString)
        if err == .success { return }
        if err == .apiDisabled {
            throw TestHarnessError.axTrustMissing
        }
        throw TestHarnessError.elementNotFound(identifier: identifier)
    }

    private func mapWindowError(_ err: AXError, title: String) throws {
        if err == .success { return }
        if err == .apiDisabled { throw TestHarnessError.axTrustMissing }
        throw TestHarnessError.elementNotFound(identifier: "window[\(title)]")
    }

    private func findDescendant(
        in element: AXUIElement,
        where matches: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        if matches(element) { return element }
        var childrenValue: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        guard err == .success, let children = childrenValue as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findDescendant(in: child, where: matches) {
                return found
            }
        }
        return nil
    }

    private func findDescendant(
        in element: AXUIElement,
        role: String,
        where matches: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        findDescendant(in: element, where: { candidate in
            var roleValue: AnyObject?
            let err = AXUIElementCopyAttributeValue(candidate, kAXRoleAttribute as CFString, &roleValue)
            guard err == .success, (roleValue as? String) == role else { return false }
            return matches(candidate)
        })
    }

    private func findDescendant(
        in element: AXUIElement,
        roles: [String],
        where matches: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        findDescendant(in: element, where: { candidate in
            var roleValue: AnyObject?
            let err = AXUIElementCopyAttributeValue(candidate, kAXRoleAttribute as CFString, &roleValue)
            guard err == .success, let role = roleValue as? String, roles.contains(role) else { return false }
            return matches(candidate)
        })
    }

    private func findAncestor(from element: AXUIElement, role: String) -> AXUIElement? {
        var current: AXUIElement = element
        while true {
            var parentValue: AnyObject?
            let err = AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentValue)
            guard err == .success,
                  let parent = parentValue,
                  CFGetTypeID(parent) == AXUIElementGetTypeID()
            else {
                return nil
            }
            // CFGetTypeID guard above proves the cast is safe; Swift can't.
            let parentElement = unsafeDowncast(parent, to: AXUIElement.self)
            if elementRole(of: parentElement) == role {
                return parentElement
            }
            current = parentElement
        }
    }

    private func elementRole(of element: AXUIElement) -> String? {
        var roleValue: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        guard err == .success else { return nil }
        return roleValue as? String
    }

    /// Polls until `popUp`'s shown menu becomes resolvable. Used by
    /// `pickPopUpItem` to absorb `cannotComplete` from `kAXShowMenuAction`
    /// (the menu may have opened anyway) and the asynchronous AX publication
    /// window after a successful action. Callers pick a short timeout for
    /// speculative probes and the full UI timeout for confirmation after a
    /// committed press fallback.
    private func waitForShownMenu(
        on popUp: AXUIElement,
        identifier: String,
        timeout: Duration = TestTimeout.uiElement
    ) async throws {
        try await pollUntil(timeout: timeout) {
            (try? self.resolveShownMenu(for: popUp, identifier: identifier)) != nil
        }
    }

    /// Polls `readValue(identifier:)` until it equals `expected`. Absorbs
    /// transient `elementNotFound` (SwiftUI re-renders the popup briefly when
    /// the binding commits).
    private func waitForValue(_ expected: String, identifier: String) async throws {
        try await pollUntil(timeout: TestTimeout.uiElement) {
            do {
                return try self.readValue(identifier: identifier) == expected
            } catch TestHarnessError.elementNotFound {
                return false
            }
        }
    }

    /// Locates the first descendant `kAXMenuItemRole` of `root` whose
    /// `kAXTitleAttribute` equals `title`. Shared between `clickMenuItem`
    /// (root = application element) and `pickPopUpItem` (root = popup's
    /// shown menu).
    private func findMenuItem(in root: AXUIElement, title: String) -> AXUIElement? {
        findDescendant(in: root, role: kAXMenuItemRole, where: { element in
            var value: AnyObject?
            let err = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
            return err == .success && (value as? String) == title
        })
    }

    private func resolveShownMenu(for popUp: AXUIElement, identifier: String) throws -> AXUIElement {
        var shownValue: AnyObject?
        let shownErr = AXUIElementCopyAttributeValue(
            popUp,
            kAXShownMenuUIElementAttribute as CFString,
            &shownValue
        )
        if shownErr == .success,
           let shownValue,
           CFGetTypeID(shownValue) == AXUIElementGetTypeID() {
            return unsafeDowncast(shownValue, to: AXUIElement.self)
        }
        if let menu = findDescendant(in: popUp, role: kAXMenuRole, where: { _ in true }) {
            return menu
        }
        throw TestHarnessError.elementNotFound(identifier: "\(identifier)/shown-menu")
    }

    private func collectIdentifiers(
        in element: AXUIElement,
        matchingPrefix prefix: String,
        into matches: inout [String]
    ) {
        var childrenValue: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        if err == .success, let children = childrenValue as? [AXUIElement] {
            for child in children {
                collectIdentifiers(in: child, matchingPrefix: prefix, into: &matches)
            }
        }
        // post-order: visit the element after its children so the last entry
        // in the resulting array is the deepest match in traversal order.
        var idValue: AnyObject?
        let idErr = AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &idValue)
        if idErr == .success, let identifier = idValue as? String, identifier.hasPrefix(prefix) {
            matches.append(identifier)
        }
    }

    private func elementCenter(of element: AXUIElement) -> CGPoint? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        let posErr = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
        let sizeErr = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        guard posErr == .success, sizeErr == .success,
              let posCF = posValue, let sizeCF = sizeValue,
              CFGetTypeID(posCF) == AXValueGetTypeID(),
              CFGetTypeID(sizeCF) == AXValueGetTypeID() else {
            return nil
        }
        // CFGetTypeID guards above prove the cast is safe; Swift can't.
        let posAXValue = unsafeDowncast(posCF, to: AXValue.self)
        let sizeAXValue = unsafeDowncast(sizeCF, to: AXValue.self)
        var origin = CGPoint.zero
        var size = CGSize.zero
        // AXValueGetValue returns false if the embedded AXValueType differs
        // from the requested one — guard the return so we don't dispatch a
        // click at (0, 0) on an unrelated geometry encoding.
        guard AXValueGetValue(posAXValue, .cgPoint, &origin),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            return nil
        }
        return CGPoint(x: origin.x + size.width / 2.0, y: origin.y + size.height / 2.0)
    }

    private func postClickPair(at point: CGPoint, clickState: Int64) {
        if let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ) {
            down.setIntegerValueField(.mouseEventClickState, value: clickState)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) {
            up.setIntegerValueField(.mouseEventClickState, value: clickState)
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Static helpers

    /// Spawns `Ducko.app` through LaunchServices via
    /// `NSWorkspace.openApplication(at:configuration:)`. Returns the new
    /// `NSRunningApplication` so the caller can drive AX queries against
    /// its PID and terminate it on teardown. `createsNewApplicationInstance`
    /// is set so each test gets its own process even when a developer's
    /// dev-build Ducko is already running.
    ///
    /// Note: `OpenConfiguration.environment` *replaces* the inherited
    /// environment for the spawned process — it does not augment it. The
    /// init's allowlist (`HOME`, `PATH`, `LANG`, `LC_ALL`, plus
    /// `DUCKO_PROFILE`) intentionally re-adds anything the app needs.
    @MainActor
    private static func openApp(
        at bundleURL: URL,
        environment: [String: String],
        arguments: [String]
    ) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = environment
        configuration.arguments = arguments
        configuration.createsNewApplicationInstance = true
        return try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
    }

    /// Polls `app.isTerminated` until the app exits or `timeout` elapses.
    /// `NSRunningApplication`'s analogue of `CLIProcess.waitForProcessExit`.
    private nonisolated static func waitForRunningAppExit(
        _ app: NSRunningApplication,
        timeout: Duration,
        pollInterval: Duration = .milliseconds(50)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if app.isTerminated { return true }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return app.isTerminated
            }
        }
        return app.isTerminated
    }

    /// Reads the bundle's Info dictionary and verifies
    /// `DuckoBuildConfiguration == "debug"`. Throws
    /// `TestHarnessError.appBundleNotDebug` otherwise.
    private static func assertDebugBundle(at bundleURL: URL) throws {
        guard let bundle = Bundle(url: bundleURL),
              let configuration = bundle.object(forInfoDictionaryKey: "DuckoBuildConfiguration") as? String,
              configuration == "debug" else {
            throw TestHarnessError.appBundleNotDebug(path: bundleURL.path)
        }
    }

    @MainActor
    private static func activateAppOnMain(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            log.debug("activateApp: NSRunningApplication(processIdentifier: \(pid)) returned nil")
            return
        }
        if !app.activate() {
            // `activate()` returns false when the app has quit or cannot be
            // brought forward. Subsequent CGEvent posts may end up at the
            // wrong frontmost app — log so timeouts are diagnosable.
            log.debug("activateApp: NSRunningApplication.activate() returned false for pid \(pid)")
        }
    }

    private nonisolated static func activateApp(pid: pid_t) async {
        await activateAppOnMain(pid: pid)
    }

    /// Sets `kAXFocusedAttribute = true` on the element and logs at debug
    /// when the AX error is non-success. Many SwiftUI controls accept value
    /// or keystroke input without taking AX focus, so failure here is not
    /// fatal — but if a downstream keystroke fallback misses its target,
    /// the breadcrumb makes the failure mode legible.
    private nonisolated static func setFocused(_ element: AXUIElement, identifier: String) {
        let err = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if err != .success {
            log.debug("setFocused: AXError \(err.rawValue) on '\(identifier)'")
        }
    }

    private nonisolated static func synthesizeKeystrokes(for text: String) {
        for scalar in text.unicodeScalars {
            var character = UniChar(min(UInt32(UInt16.max), scalar.value))
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
                up.post(tap: .cghidEventTap)
            }
        }
    }
}
