import DuckoCore
import SwiftUI

/// App-owned state for the single tabbed chat window. Retains each open tab's
/// `ChatWindowState` in `states` so switching tabs never destroys per-conversation UI
/// state (draft, search, reply/edit, sidebar). Tab keys are the full open-string
/// (`room@conf/nick` for a MUC PM is a distinct key from the room's `room@conf`), matching
/// how `ChatWindowState.load()` disambiguates them.
@MainActor @Observable
public final class ChatContainerState {
    public private(set) var orderedTabs: [String] = []
    private var states: [String: ChatWindowState] = [:]
    public var selectedJID: String?

    /// Drives the container-owned New Chat sheet so the tab-bar "+" and the menu-bar
    /// New Chat command work when the chat window is frontmost — the Contacts window
    /// (owner of the original new-chat sheet) isn't the focused scene then.
    public var isShowingNewChat = false

    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var selectedState: ChatWindowState? {
        selectedJID.flatMap { states[$0] }
    }

    public var hasTabs: Bool {
        !orderedTabs.isEmpty
    }

    public func state(for jidString: String) -> ChatWindowState? {
        states[jidString]
    }

    // MARK: - Tab Lifecycle

    public func open(_ jidString: String) {
        if states[jidString] == nil {
            let state = ChatWindowState(jidString: jidString, environment: environment)
            states[jidString] = state
            orderedTabs.append(jidString)
            selectedJID = jidString
            // `load()` ends by calling `chatService.selectConversation`, so the freshly
            // opened tab becomes the active conversation without a separate activation.
            // Bump the generation so any in-flight select/close activation finds itself
            // stale and bails instead of re-pointing the active conversation behind this
            // newly opened, now-selected tab.
            activationGeneration += 1
            Task { await state.load() }
        } else {
            select(jidString)
        }
    }

    public func select(_ jidString: String) {
        guard let state = states[jidString], selectedJID != jidString else { return }
        selectedJID = jidString
        scheduleActivation(of: state)
    }

    public func close(_ jidString: String) {
        guard let index = orderedTabs.firstIndex(of: jidString) else { return }
        orderedTabs.remove(at: index)
        states.removeValue(forKey: jidString)

        guard selectedJID == jidString else { return }
        // Pick the tab that shifted into this slot, else the new last tab.
        let neighbor = orderedTabs.indices.contains(index) ? orderedTabs[index] : orderedTabs.last
        selectedJID = neighbor
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
