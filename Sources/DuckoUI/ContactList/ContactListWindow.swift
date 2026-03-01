import DuckoCore
import SwiftUI

struct ContactListWindow: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    @State private var searchText = ""
    @State private var isShowingNewChat = false
    @State private var isShowingAddContact = false

    private var account: Account? {
        environment.accountService.accounts.first
    }

    var body: some View {
        VStack(spacing: 0) {
            StatusBarView()

            Divider()

            SubscriptionRequestBanner()

            ContactListView(searchText: searchText)
        }
        .searchable(text: $searchText, placement: .toolbar)
        .toolbar {
            ToolbarItem {
                Button {
                    isShowingAddContact = true
                } label: {
                    Label("Add Contact", systemImage: "person.badge.plus")
                }
            }

            ToolbarItem {
                Button {
                    isShowingNewChat = true
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
            }
        }
        .task {
            guard let accountID = account?.id else { return }
            // Auto-connect if disconnected
            switch environment.accountService.connectionStates[accountID] {
            case .connected:
                break
            default:
                try? await environment.accountService.connect(accountID: accountID)
            }
        }
        .task(id: account?.id) {
            guard let accountID = account?.id else { return }
            try? await environment.chatService.loadConversations(for: accountID)
            try? await environment.rosterService.loadContacts(for: accountID)
            environment.presenceService.startIdleMonitoring(accountID: accountID)
            await environment.rosterService.fetchAvatars(accountID: accountID)
        }
        .sheet(isPresented: $isShowingNewChat) {
            NewChatSheet { jidString in
                openWindow(id: "chat", value: jidString)
            }
        }
        .sheet(isPresented: $isShowingAddContact) {
            AddContactSheet()
        }
    }
}
