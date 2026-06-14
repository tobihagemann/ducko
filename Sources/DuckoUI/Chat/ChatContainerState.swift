import DuckoCore
import SwiftUI

/// App-owned state for the single tabbed chat window. Retains each open tab's
/// `ChatWindowState` in `states` so switching tabs never destroys per-conversation UI
/// state (draft, search, reply/edit, sidebar). Tabs are keyed by `ConversationKey`
/// (account + full open-string JID), so the same peer JID under two accounts opens two
/// distinct tabs, and a MUC PM (`room@conf/nick`) stays distinct from the room (`room@conf`).
@MainActor @Observable
public final class ChatContainerState {
    public private(set) var orderedTabs: [ConversationKey] = []
    private var states: [ConversationKey: ChatWindowState] = [:]
    public var selectedKey: ConversationKey?

    /// Drives the container-owned New Chat sheet so the tab-bar "+" and the menu-bar
    /// New Chat command work when the chat window is frontmost — the Contacts window
    /// (owner of the original new-chat sheet) isn't the focused scene then.
    public var isShowingNewChat = false

    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var selectedState: ChatWindowState? {
        selectedKey.flatMap { states[$0] }
    }

    public var hasTabs: Bool {
        !orderedTabs.isEmpty
    }

    public func state(for key: ConversationKey) -> ChatWindowState? {
        states[key]
    }

    // MARK: - Tab Lifecycle

    public func open(_ jidString: String, accountID: UUID?) {
        let key = ConversationKey(accountID: accountID, jid: jidString)
        if states[key] == nil {
            let state = ChatWindowState(jidString: jidString, accountID: accountID, environment: environment)
            states[key] = state
            orderedTabs.append(key)
            selectedKey = key
            // `load()` ends by calling `chatService.selectConversation`, so the freshly
            // opened tab becomes the active conversation without a separate activation.
            // Bump the generation so any in-flight select/close activation finds itself
            // stale and bails instead of re-pointing the active conversation behind this
            // newly opened, now-selected tab.
            activationGeneration += 1
            Task { await state.load() }
        } else {
            select(key)
        }
    }

    public func select(_ key: ConversationKey) {
        guard let state = states[key], selectedKey != key else { return }
        selectedKey = key
        scheduleActivation(of: state)
    }

    public func close(_ key: ConversationKey) {
        guard let index = orderedTabs.firstIndex(of: key) else { return }
        orderedTabs.remove(at: index)
        states.removeValue(forKey: key)

        guard selectedKey == key else { return }
        // Pick the tab that shifted into this slot, else the new last tab.
        let neighbor = orderedTabs.indices.contains(index) ? orderedTabs[index] : orderedTabs.last
        selectedKey = neighbor
        if let neighbor, let state = states[neighbor] {
            scheduleActivation(of: state)
        } else {
            scheduleDeactivation()
        }
    }

    public func newChat() {
        isShowingNewChat = true
    }

    // MARK: - Activation

    /// Bumped on every activation request. A stale activation still mid-`await` when the
    /// user selects a newer tab finds its generation no longer current and discards itself,
    /// rather than re-pointing the active conversation (and marking it read) behind the
    /// now-visible tab.
    private var activationGeneration = 0

    private func scheduleActivation(of state: ChatWindowState) {
        activationGeneration += 1
        let generation = activationGeneration
        Task { await activate(state, generation: generation) }
    }

    /// Clears `ChatService.activeConversationID` when the last tab closes. Otherwise it
    /// keeps pointing at the just-closed conversation, which `ChatService` treats as
    /// active — auto-marking its incoming messages read and suppressing their unread count.
    private func scheduleDeactivation() {
        activationGeneration += 1
        let generation = activationGeneration
        Task {
            guard generation == activationGeneration else { return }
            await environment.chatService.selectConversation(nil)
        }
    }

    /// Re-points `ChatService.activeConversationID` at the now-visible tab and refreshes
    /// its messages. `selectConversation` reloads `ChatService.messages` and marks read but
    /// does not touch the tab's retained `ChatWindowState.messages`, so we refresh it
    /// directly rather than relying on the order/equality-fragile `.onChange` observers —
    /// otherwise a freshly-activated hidden tab could be marked read while showing stale
    /// messages received while it was hidden.
    private func activate(_ state: ChatWindowState, generation: Int) async {
        guard generation == activationGeneration else { return }
        guard let conversationID = state.conversation?.id else { return }
        let accountID = state.conversation?.accountID ?? environment.accountService.accounts.first?.id
        await environment.chatService.selectConversation(conversationID, accountID: accountID)
        guard generation == activationGeneration else { return }
        await state.refreshMessages()
    }
}
