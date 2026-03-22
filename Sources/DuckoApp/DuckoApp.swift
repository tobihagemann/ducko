import AppKit
import DuckoCore
import DuckoData
import DuckoUI
import SwiftData
import SwiftUI

@main
struct DuckoApp: App {
    @State private var environment: AppEnvironment
    @State private var themeEngine = ThemeEngine()
    @State private var updateManager = UpdateManager()
    @State private var notificationManager = NotificationManager()
    @FocusedValue(\.chatTabManager) private var focusedTabManager
    @Environment(\.openWindow) private var openWindow
    @State private var isShowingAdiumImport = false

    init() {
        LoggingConfiguration.bootstrap()
        NSApplication.shared.setActivationPolicy(.regular)
        do {
            let container = try ModelContainerFactory.makeContainer()
            let store = SwiftDataPersistenceStore(modelContainer: container)
            let omemoStore = SwiftDataOMEMOStore(modelContainer: container)
            let env = AppEnvironment(store: store, omemoStore: omemoStore, linkPreviewFetcher: LPLinkPreviewFetcher())
            self.environment = env
            AppStateObserver(accountService: env.accountService)
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }

    var body: some Scene {
        Window("Contacts", id: "contacts") {
            ContentView()
                .environment(environment)
                .environment(themeEngine)
                .task {
                    notificationManager.requestAuthorization()
                    wireNotifications()
                    try? await environment.accountService.loadAccounts()
                    await environment.accountService.connectEnabledAccounts()
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
                    focusedTabManager?.toggleSearch()
                }
                .keyboardShortcut("f")
            }

            CommandGroup(after: .help) {
                Button("Export Logs...") {
                    exportLogs()
                }
            }

            CommandMenu("Tab") {
                Button("Close Tab") {
                    focusedTabManager?.closeSelectedTab()
                }
                .keyboardShortcut("w")

                Divider()

                Button("Next Tab") {
                    focusedTabManager?.selectNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Previous Tab") {
                    focusedTabManager?.selectPreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Divider()

                ForEach(1 ... 9, id: \.self) { n in
                    Button("Tab \(n)") {
                        focusedTabManager?.selectTab(at: n - 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")))
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
