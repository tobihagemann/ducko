import DuckoCore
import SwiftUI

struct ChatView: View {
    @Environment(AppEnvironment.self) private var environment
    let windowState: ChatWindowState

    var body: some View {
        VStack(spacing: 0) {
            if let conversation = windowState.conversation {
                ChatHeaderView(conversation: conversation, windowState: windowState)

                Divider()

                if windowState.isGroupchat {
                    RoomSubjectView(windowState: windowState)

                    Divider()
                }
            }

            IncomingFileTransferBanner()

            if windowState.isSearching {
                MessageSearchBar(windowState: windowState)

                Divider()
            }

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    MessageListView(windowState: windowState)

                    if windowState.isPartnerTyping {
                        TypingIndicatorView()
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    TransferProgressView()

                    Divider()

                    MessageInputView(windowState: windowState)
                }

                if windowState.isGroupchat, windowState.showParticipantSidebar {
                    Divider()

                    ParticipantSidebar(roomJIDString: windowState.jidString)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .fileDropTarget(windowState: windowState)
        .animation(.easeInOut(duration: 0.2), value: windowState.isPartnerTyping)
        .animation(.easeInOut(duration: 0.2), value: windowState.showParticipantSidebar)
    }
}
