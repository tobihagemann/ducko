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
    var positions: [UUID: MessagePosition] = [:]

    // Date-based detail navigation
    var messageDates: [Date] = []
    var messageDateCounts: [Date: Int] = [:]
    var selectedDate: Date?

    // Sidebar filters
    var searchText = ""
    var typeFilter: ConversationTypeFilter = .all

    // Detail search
    var transcriptSearchText = ""
    var searchResults: Set<UUID> = []
    var searchMatchDates: Set<Date> = []

    /// Loading
    var isLoading = false

    private let environment: AppEnvironment

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

    private var partitionedConversations: (byAccount: [UUID: [Conversation]], importedBySource: [String: [Conversation]]) {
        let filtered = filteredConversations
        var grouped: [UUID: [Conversation]] = [:]
        var importedBySource: [String: [Conversation]] = [:]
        for conversation in filtered {
            if let accountID = conversation.accountID {
                grouped[accountID, default: []].append(conversation)
            } else {
                let key = conversation.importSourceJID ?? "Unknown"
                importedBySource[key, default: []].append(conversation)
            }
        }
        return (grouped, importedBySource)
    }

    var conversationsByAccount: [(account: Account, conversations: [Conversation])] {
        let grouped = partitionedConversations.byAccount
        return accounts.compactMap { account in
            guard let convs = grouped[account.id], !convs.isEmpty else { return nil }
            return (account, convs)
        }
    }

    var importedConversationsBySource: [(sourceJID: String, conversations: [Conversation])] {
        partitionedConversations.importedBySource
            .sorted { $0.key < $1.key }
            .map { (sourceJID: $0.key, conversations: $0.value) }
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
        positions = [:]
        messageDates = []
        messageDateCounts = [:]
        selectedDate = nil
        searchResults = []
        searchMatchDates = []
        transcriptSearchText = ""

        guard let conversation else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let dateCounts = try await environment.chatService.conversationMessageDateCounts(conversation.id)
            messageDates = dateCounts.map(\.date)
            messageDateCounts = Dictionary(uniqueKeysWithValues: dateCounts)
            // Auto-select the most recent date
            if let latestDate = messageDates.first {
                await selectDate(latestDate)
            }
        } catch {
            log.error("Failed to load message dates: \(error)")
        }
    }

    func selectDate(_ date: Date?) async {
        selectedDate = date
        messages = []
        positions = [:]

        guard let date, let conversation = selectedConversation else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            messages = try await environment.chatService.fetchMessageHistory(
                for: conversation.id, on: date
            )
            positions = computeMessagePositions(messages)
        } catch {
            log.error("Failed to load messages for date: \(error)")
        }
    }

    func performTranscriptSearch() async {
        let query = transcriptSearchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let conversation = selectedConversation else {
            searchResults = []
            searchMatchDates = []
            return
        }

        do {
            let results = try await environment.chatService.searchTranscripts(
                query: query, conversationID: conversation.id, limit: 500
            )
            searchResults = Set(results.map(\.id))

            // Compute which dates have matches for highlighting in the date table
            // Use GMT to match FileTranscriptStore's date convention
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            searchMatchDates = Set(results.map { calendar.startOfDay(for: $0.timestamp) })
        } catch {
            log.error("Failed to search transcripts: \(error)")
        }
    }
}
