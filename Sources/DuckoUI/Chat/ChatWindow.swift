import DuckoCore
import SwiftUI

public struct ChatWindow: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var jidString: String?
    @State private var tabManager = ChatTabManager()

    public init(jidString: Binding<String?>) {
        _jidString = jidString
    }

    public var body: some View {
        VStack(spacing: 0) {
            if tabManager.tabs.count > 1 {
                ChatTabBar(tabManager: tabManager)

                Divider()
            }

            if let tab = tabManager.selectedTab, let windowState = tab.windowState, !windowState.isLoading {
                ChatView(windowState: windowState)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(tabManager.selectedTab?.windowState?.conversation?.displayName ?? jidString ?? "Chat")
        .task(id: jidString) {
            guard let jid = jidString else { return }
            let tabID = tabManager.openTab(jidString: jid, environment: environment)
            if let tab = tabManager.tabs.first(where: { $0.id == tabID }) {
                await tab.windowState?.load()
            }
        }
        .onChange(of: environment.chatService.openConversations.first(where: { $0.jid.description == tabManager.selectedTab?.jidString })?.lastMessageDate) {
            Task {
                await tabManager.selectedTab?.windowState?.refreshMessages()
            }
        }
        .focusedSceneValue(\.chatTabManager, tabManager)
    }
}
