import DuckoCore
import Logging
import SwiftUI

private let log = Logger(label: "im.ducko.ui.transcripts")

@MainActor @Observable
final class TranscriptViewerState {
    var allConversations: [Conversation] = []
    var accounts: [Account] = []
    var selectedConversation: Conversation?
    var messages: [ChatMessage] = []

    // Sidebar filters
    var searchText = ""
    var dateFilter: TranscriptDateFilter = .anyTime
    var typeFilter: ConversationTypeFilter = .all

    // Detail search
    var transcriptSearchText = ""
    var searchResults: Set<UUID> = []

    // Loading
    var isLoading = false
    var isLoadingOlder = false
    var hasReachedEnd = false

    private let environment: AppEnvironment
    private let pageSize = 50

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    // MARK: - Computed

    var filteredConversations: [Conversation] {
        var result = allConversations

        // Type filter
        switch typeFilter {
        case .all: break
        case .chats: result = result.filter { $0.type == .chat }
        case .rooms: result = result.filter { $0.type == .groupchat }
        }

        // Date filter
        if dateFilter != .anyTime {
            let interval = dateFilter.dateInterval
            result = result.filter { conversation in
                guard let date = conversation.lastMessageDate else { return false }
                if let after = interval.after, date < after { return false }
                if let before = interval.before, date > before { return false }
                return true
            }
        }

        // Search filter
        if !searchText.isEmpty {
            result = result.filter { conversation in
                let name = conversation.displayName ?? conversation.jid.description
                return name.localizedCaseInsensitiveContains(searchText)
                    || conversation.jid.description.localizedCaseInsensitiveContains(searchText)
            }
        }

        return result
    }

    var conversationsByAccount: [(account: Account, conversations: [Conversation])] {
        let filtered = filteredConversations
        var grouped: [UUID: [Conversation]] = [:]
        for conversation in filtered {
            grouped[conversation.accountID, default: []].append(conversation)
        }
        return accounts.compactMap { account in
            guard let convs = grouped[account.id], !convs.isEmpty else { return nil }
            return (account, convs)
        }
    }

    // MARK: - Actions

    func clearSelectionIfFiltered() async {
        if let selected = selectedConversation,
           !filteredConversations.contains(where: { $0.id == selected.id }) {
            await selectConversation(nil)
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await environment.accountService.loadAccounts()
            accounts = environment.accountService.accounts
            allConversations = try await environment.chatService.fetchAllConversations()
        } catch {
            log.error("Failed to load transcripts: \(error)")
        }
    }

    func selectConversation(_ conversation: Conversation?) async {
        selectedConversation = conversation
        messages = []
        hasReachedEnd = false
        searchResults = []
        transcriptSearchText = ""

        guard let conversation else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let fetched = try await environment.chatService.fetchMessageHistory(
                for: conversation.id, before: nil, limit: pageSize
            )
            messages = fetched
            hasReachedEnd = fetched.count < pageSize
        } catch {
            log.error("Failed to load messages: \(error)")
        }
    }

    func loadOlderMessages() async {
        guard !isLoadingOlder, !hasReachedEnd, let conversation = selectedConversation else { return }

        isLoadingOlder = true
        defer { isLoadingOlder = false }

        do {
            let oldest = messages.first?.timestamp
            let older = try await environment.chatService.fetchMessageHistory(
                for: conversation.id, before: oldest, limit: pageSize
            )
            if older.isEmpty {
                hasReachedEnd = true
            } else {
                messages.insert(contentsOf: older, at: 0)
                hasReachedEnd = older.count < pageSize
            }
        } catch {
            log.error("Failed to load older messages: \(error)")
        }
    }

    func performTranscriptSearch() async {
        let query = transcriptSearchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let conversation = selectedConversation else {
            searchResults = []
            return
        }

        do {
            let results = try await environment.chatService.searchTranscripts(
                query: query, conversationID: conversation.id, limit: 500
            )
            searchResults = Set(results.map(\.id))
        } catch {
            log.error("Failed to search transcripts: \(error)")
        }
    }
}
