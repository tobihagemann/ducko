import DuckoCore
import SwiftUI

struct ContactListWindow: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    @State private var searchText = ""
    @State private var isShowingNewChat = false
    @State private var isShowingAddContact = false
    @State private var isShowingJoinRoom = false
    @State private var isShowingProfile = false
    @State private var preferences = ContactListPreferences()

    private var account: Account? {
        environment.accountService.accounts.first { $0.isEnabled }
    }

    var body: some View {
        VStack(spacing: 0) {
            StatusBarView()

            Divider()

            SubscriptionRequestBanner()

            RoomInviteBanner()

            ContactListView(searchText: searchText, preferences: preferences)
        }
        .searchable(text: $searchText, placement: .toolbar)
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Sort by", selection: Bindable(preferences).sortMode) {
                        ForEach(ContactListSortMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }

                    Divider()

                    Toggle("Hide Offline", isOn: Bindable(preferences).hideOffline)
                } label: {
                    Label("View Options", systemImage: "line.3.horizontal.decrease.circle")
                }
                .accessibilityIdentifier("sort-mode-menu")
            }

            ToolbarItem {
                Button {
                    isShowingProfile = true
                } label: {
                    Label("My Profile", systemImage: "person.crop.circle")
                }
                .accessibilityIdentifier("my-profile-toolbar-button")
            }

            ToolbarItem {
                Button {
                    isShowingAddContact = true
                } label: {
                    Label("Add Contact", systemImage: "person.badge.plus")
                }
            }

            ToolbarItem {
                Button {
                    isShowingJoinRoom = true
                } label: {
                    Label("Join Room", systemImage: "bubble.left.and.bubble.right")
                }
                .accessibilityIdentifier("join-room-toolbar-button")
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
        .sheet(isPresented: $isShowingJoinRoom) {
            RoomJoinDialog { jidString in
                openWindow(id: "chat", value: jidString)
            }
        }
        .sheet(isPresented: $isShowingProfile) {
            ProfileEditView()
        }
    }
}
