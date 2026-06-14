import DuckoCore
import SwiftUI

public struct ChatContainerView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ChatContainerState.self) private var container

    public init() {}

    private var observedLastMessageDate: Date? {
        environment.chatService.openConversations
            .first { $0.id == container.selectedState?.conversation?.id }?
            .lastMessageDate
    }

    private var observedMessagesRevision: Int? {
        guard let id = container.selectedState?.conversation?.id else { return nil }
        return environment.chatService.messagesRevisions[id]
    }

    public var body: some View {
        @Bindable var container = container

        VStack(spacing: 0) {
            if let state = container.selectedState {
                ChatView(windowState: state)
            } else {
                emptyState
            }

            Divider()

            ChatTabBarView(container: container)
        }
        .frame(minWidth: 380, minHeight: 320)
        .navigationTitle(container.selectedState?.conversation?.displayName ?? "Chat")
        .focusedSceneValue(\.chatWindowState, container.selectedState)
        .onChange(of: observedLastMessageDate) {
            Task { await container.selectedState?.refreshMessages() }
        }
        .onChange(of: observedMessagesRevision) {
            Task { await container.selectedState?.refreshMessages() }
        }
        .sheet(isPresented: $container.isShowingNewChat) {
            NewChatSheet { jidString, accountID in
                container.open(jidString, accountID: accountID)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No conversation open")
                .foregroundStyle(.secondary)
            Button("New Chat") {
                container.newChat()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("chat-empty-state")
    }
}
