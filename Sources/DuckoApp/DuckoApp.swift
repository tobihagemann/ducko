import AppKit
import DuckoCore
import DuckoData
import DuckoUI
import Logging
import SwiftData
import SwiftUI

private let log = Logger(label: "im.ducko.app.lifecycle")

@main
struct DuckoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment: AppEnvironment
    @State private var themeEngine = ThemeEngine()
    @State private var updateManager = UpdateManager()
    @State private var notificationManager = NotificationManager()
    @FocusedValue(\.chatWindowState) private var focusedChatWindowState
    @Environment(\.openWindow) private var openWindow
    @State private var isShowingAdiumImport = false

    init() {
        LoggingConfiguration.bootstrap()
        NSApplication.shared.setActivationPolicy(.regular)
        do {
            let container = try ModelContainerFactory.makeContainer()
            let store = SwiftDataPersistenceStore(modelContainer: container)
            let omemoStore = SwiftDataOMEMOStore(modelContainer: container)
            let transcripts = FileTranscriptStore.makeDefault()
            let env = AppEnvironment(store: store, transcripts: transcripts, omemoStore: omemoStore, linkPreviewFetcher: LPLinkPreviewFetcher())
            self.environment = env
            AppStateObserver(accountService: env.accountService)
            AppDelegate.accountService = env.accountService
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }

    var body: some Scene {
        Window("Welcome", id: "welcome") {
            WelcomeView()
                .environment(environment)
                .environment(themeEngine)
        }
        .defaultSize(width: 520, height: 620)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Contacts", id: "contacts") {
            ContentView()
                .environment(environment)
                .environment(themeEngine)
                .task {
                    notificationManager.requestAuthorization()
                    wireNotifications()
                }
                .onChange(of: totalUnread) { _, newValue in
                    notificationManager.updateDockBadge(totalUnread: newValue)
                }
                .sheet(isPresented: $isShowingAdiumImport) {
                    AdiumImportView()
                        .environment(environment)
                }
        }
        .defaultSize(width: 280, height: 600)
        .defaultPosition(.topLeading)
        .defaultLaunchBehavior(.presented)

        WindowGroup("Chat", id: "chat", for: String.self) { $jidString in
            ChatWindow(jidString: $jidString)
                .environment(environment)
                .environment(themeEngine)
        }
        .defaultSize(width: 500, height: 450)

        Window("Chat Transcripts", id: "transcripts") {
            TranscriptViewerWindow()
                .environment(environment)
                .environment(themeEngine)
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updateManager.checkForUpdates()
                }
                .disabled(!updateManager.canCheckForUpdates)

                Button("Install Command Line Tools...") {
                    CLIInstaller.installCLITools()
                }
            }

            CommandGroup(after: .newItem) {
                Divider()

                Button("Chat Transcripts") {
                    openWindow(id: "transcripts")
                }
                .keyboardShortcut("t", modifiers: [.command, .option])

                Divider()

                Button("Import Adium Logs...") {
                    isShowingAdiumImport = true
                }
            }

            CommandGroup(replacing: .textEditing) {
                Button("Find...") {
                    focusedChatWindowState?.toggleSearch()
                }
                .keyboardShortcut("f")
                .disabled(focusedChatWindowState == nil)
            }

            CommandGroup(after: .help) {
                Button("Export Logs...") {
                    exportLogs()
                }
            }
        }

        MenuBarExtra("Ducko", systemImage: "bubble.left.and.bubble.right.fill") {
            MenuBarStatusView()
                .environment(environment)
                .environment(themeEngine)
        }

        Settings {
            PreferencesView()
                .environment(environment)
                .environment(themeEngine)
        }
    }

    private var totalUnread: Int {
        environment.chatService.openConversations.reduce(0) { $0 + $1.unreadCount }
    }

    private func wireNotifications() {
        environment.chatService.onIncomingMessage = { [weak notificationManager] message, conversation in
            guard let notificationManager else { return }
            guard !conversation.isMuted else { return }
            guard conversation.id != environment.chatService.activeConversationID else { return }

            let senderName = conversation.displayName ?? conversation.jid.description
            notificationManager.postMessageNotification(
                from: senderName,
                body: message.body,
                jidString: conversation.jid.description,
                avatarData: nil
            )
        }

        notificationManager.onNotificationTapped = { [openWindow] jidString in
            openWindow(id: "chat", value: jidString)
        }
    }

    private func exportLogs() {
        let panel = NSSavePanel()
        let dateString = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "ducko-logs-\(dateString)"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            _ = try LogExporter.export(to: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}

// MARK: - App Lifecycle Observer

/// Observes NSApplication active/resign notifications for XEP-0352 CSI.
/// Retained by `DuckoApp` for the app's lifetime, independent of any window.
@MainActor
private final class AppStateObserver {
    init(accountService: AccountService) {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in Task { @MainActor in await accountService.setAppActive(true) } }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { _ in Task { @MainActor in await accountService.setAppActive(false) } }
    }
}

// MARK: - App Delegate

/// Sends unavailable presence and `</stream:stream>` per RFC 6120 §4.4 before
/// the process exits. Without this, SIGTERM (or `app.terminate()` from the UI
/// integration test harness) leaves the server holding the resource bound for
/// 30-90 s, which collides with the next test's bind.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak static var accountService: AccountService?

    /// Bound on `disconnectAll`. A stuck TCP/TLS write must not be allowed to
    /// hold AppKit's terminate-later reply forever — the user can already see
    /// the app refusing to quit, and AppKit's own (~60 s) failsafe is too long.
    static let disconnectDeadline: Duration = .seconds(3)

    /// Runs the bounded disconnect that `applicationShouldTerminate` issues
    /// before replying to AppKit. Extracted so unit tests can exercise the
    /// disconnect path without standing up an `NSApplication` host.
    static func performShutdown(_ accountService: AccountService) async {
        log.info("applicationShouldTerminate fired; awaiting disconnectAll")
        await accountService.disconnectAll(within: disconnectDeadline)
        log.info("disconnectAll completed (or timed out); replying terminate")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let accountService = Self.accountService else { return .terminateNow }
        Task { @MainActor in
            await Self.performShutdown(accountService)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
