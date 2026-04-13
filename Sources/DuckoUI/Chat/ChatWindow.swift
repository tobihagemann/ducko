import DuckoCore
import SwiftUI

public struct ChatWindow: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var jidString: String?
    @State private var windowState: ChatWindowState?

    private var observedLastMessageDate: Date? {
        environment.chatService.openConversations
            .first(where: { $0.id == windowState?.conversation?.id })?
            .lastMessageDate
    }

    public init(jidString: Binding<String?>) {
        _jidString = jidString
    }

    public var body: some View {
        content
            .navigationTitle(windowState?.conversation?.displayName ?? jidString ?? "Chat")
            .task(id: jidString) {
                guard let jid = jidString else { return }
                // WindowGroup(for: String.self) scenes should never retarget to a
                // different JID. A retarget would reintroduce the draft/search/sidebar
                // state-loss the deleted multi-tab code was handling. Catch it loudly
                // in debug; release falls through to reuse whatever state is present.
                if let existing = windowState, existing.jidString != jid {
                    assertionFailure("ChatWindow retargeted from \(existing.jidString) to \(jid) — invariant broken")
                }
                // Dedup state creation so same-JID task re-fires (scene restoration,
                // view reappearance) preserve transient window state like search,
                // reply/edit context, participant sidebar, and pending attachments.
                if windowState == nil {
                    windowState = ChatWindowState(jidString: jid, environment: environment)
                }
                await windowState?.load()
            }
            .onChange(of: observedLastMessageDate) {
                Task {
                    await windowState?.refreshMessages()
                }
            }
            .focusedSceneValue(\.chatWindowState, windowState)
    }

    @ViewBuilder
    private var content: some View {
        if let windowState, !windowState.isLoading {
            ChatView(windowState: windowState)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
