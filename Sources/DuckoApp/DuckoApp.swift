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

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        do {
            let container = try ModelContainerFactory.makeContainer()
            let store = SwiftDataPersistenceStore(modelContainer: container)
            self.environment = AppEnvironment(store: store, linkPreviewFetcher: LPLinkPreviewFetcher())
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
        }
        .defaultSize(width: 280, height: 600)
        .defaultLaunchBehavior(.presented)

        WindowGroup("Chat", id: "chat", for: String.self) { $jidString in
            ChatWindow(jidString: $jidString)
                .environment(environment)
                .environment(themeEngine)
        }
        .defaultSize(width: 500, height: 450)
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
            }

            CommandGroup(replacing: .textEditing) {
                Button("Find...") {
                    focusedTabManager?.toggleSearch()
                }
                .keyboardShortcut("f")
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
}
