import DuckoCore
import SwiftUI

struct MainChatView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selectedConversationID: UUID?
    @State private var isShowingNewChat = false

    private var account: Account? {
        environment.accountService.accounts.first
    }

    var body: some View {
        NavigationSplitView {
            ConversationListView(selectedConversationID: $selectedConversationID)
                .toolbar {
                    ToolbarItem {
                        Button {
                            isShowingNewChat = true
                        } label: {
                            Label("New Chat", systemImage: "square.and.pencil")
                        }
                    }
                }
        } detail: {
            if let selectedConversationID,
               let conversation = environment.chatService.openConversations.first(where: { $0.id == selectedConversationID }) {
                ChatView(conversation: conversation)
            } else {
                ContentUnavailableView("No Conversation Selected", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .task {
            guard let accountID = account?.id else { return }
            try? await environment.chatService.loadConversations(for: accountID)
            // Auto-connect if disconnected and Keychain password exists
            switch environment.accountService.connectionStates[accountID] {
            case .connected:
                break
            default:
                try? await environment.accountService.connect(accountID: accountID)
            }
        }
        .onChange(of: selectedConversationID) {
            Task {
                await environment.chatService.selectConversation(selectedConversationID, accountID: account?.id)
            }
        }
        .sheet(isPresented: $isShowingNewChat) {
            NewChatSheet(selectedConversationID: $selectedConversationID)
        }
    }
}
