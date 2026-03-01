import DuckoCore
import SwiftUI

@MainActor @Observable
final class ChatWindowState {
    var conversation: Conversation?
    var messages: [ChatMessage] = []
    var isLoading = false

    // MARK: - Reply/Edit State

    var replyingTo: ChatMessage?
    var editingMessage: ChatMessage?

    // MARK: - Infinite Scroll

    var isLoadingOlder = false
    var hasReachedEnd = false

    // MARK: - Search

    var searchText = ""
    var isSearching = false
    var searchResults: [UUID] = []
    var currentSearchIndex = 0

    let jidString: String
    private let environment: AppEnvironment

    init(jidString: String, environment: AppEnvironment) {
        self.jidString = jidString
        self.environment = environment
    }

    // MARK: - Public API

    func load() async {
        guard let accountID = environment.accountService.accounts.first?.id else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let conv = try await environment.chatService.openConversation(jidString: jidString, accountID: accountID)
            conversation = conv
            messages = await environment.chatService.loadMessages(for: conv.id)
            await environment.chatService.selectConversation(conv.id, accountID: accountID)
        } catch {
            // Conversation creation failed — leave state empty
        }
    }

    func refreshMessages() async {
        guard let conversationID = conversation?.id else { return }
        messages = await environment.chatService.loadMessages(for: conversationID)
    }

    func sendMessage(_ body: String) async {
        guard let accountID = environment.accountService.accounts.first?.id else { return }

        do {
            if let editing = editingMessage, let stanzaID = editing.stanzaID {
                try await environment.chatService.sendCorrection(
                    toJIDString: jidString,
                    originalStanzaID: stanzaID,
                    newBody: body,
                    accountID: accountID
                )
            } else if let replyTo = replyingTo, let stanzaID = replyTo.stanzaID {
                try await environment.chatService.sendReply(
                    toJIDString: jidString,
                    body: body,
                    replyToStanzaID: stanzaID,
                    accountID: accountID
                )
            } else {
                try await environment.chatService.sendMessage(toJIDString: jidString, body: body, accountID: accountID)
            }
        } catch {
            // Send failed — messages stay as-is
        }

        cancelReplyOrEdit()
    }

    func userIsTyping() async {
        guard let accountID = environment.accountService.accounts.first?.id else { return }
        await environment.chatService.userIsTyping(inJIDString: jidString, accountID: accountID)
    }

    /// Whether the chat partner is currently composing.
    var isPartnerTyping: Bool {
        environment.chatService.isPartnerTyping(jidString: jidString)
    }

    // MARK: - Reply/Edit

    func startReply(to message: ChatMessage) {
        editingMessage = nil
        replyingTo = message
    }

    func startEdit(of message: ChatMessage) {
        replyingTo = nil
        editingMessage = message
    }

    func cancelReplyOrEdit() {
        replyingTo = nil
        editingMessage = nil
    }

    // MARK: - Infinite Scroll

    func loadOlderMessages() async {
        guard let conversationID = conversation?.id else { return }
        guard !isLoadingOlder, !hasReachedEnd else { return }

        isLoadingOlder = true
        defer { isLoadingOlder = false }

        do {
            let older = try await environment.chatService.fetchMessageHistory(
                for: conversationID,
                before: messages.first?.timestamp,
                limit: 50
            )

            if older.isEmpty {
                hasReachedEnd = true
            } else {
                messages = older + messages
            }
        } catch {
            // Failed to load older messages
        }
    }

    // MARK: - Search

    func performSearch() {
        guard !searchText.isEmpty else {
            searchResults = []
            return
        }

        searchResults = messages
            .filter { $0.body.localizedStandardContains(searchText) }
            .map(\.id)
        currentSearchIndex = searchResults.isEmpty ? 0 : searchResults.count - 1
    }

    func nextSearchResult() {
        guard !searchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex + 1) % searchResults.count
    }

    func previousSearchResult() {
        guard !searchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex - 1 + searchResults.count) % searchResults.count
    }

    func dismissSearch() {
        isSearching = false
        searchText = ""
        searchResults = []
        currentSearchIndex = 0
    }
}
