import DuckoCore
import SwiftUI

public struct ChatWindow: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var jidString: String?
    @State private var windowState: ChatWindowState?

    public init(jidString: Binding<String?>) {
        _jidString = jidString
    }

    public var body: some View {
        Group {
            if let windowState, !windowState.isLoading {
                ChatView(windowState: windowState)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(windowState?.conversation?.displayName ?? jidString ?? "Chat")
        .task(id: jidString) {
            guard let jid = jidString else { return }
            let state = ChatWindowState(jidString: jid, environment: environment)
            windowState = state
            await state.load()
        }
        .onChange(of: environment.chatService.openConversations.first(where: { $0.jid.description == jidString })?.lastMessageDate) {
            Task {
                await windowState?.refreshMessages()
            }
        }
    }
}
