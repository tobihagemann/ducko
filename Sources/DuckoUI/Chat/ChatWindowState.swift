import DuckoCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class ChatWindowState {
    var conversation: Conversation?
    var messages: [ChatMessage] = []
    var isLoading = false

    // MARK: - Reply/Edit State

    var replyingTo: ChatMessage?
    var editingMessage: ChatMessage?

    // MARK: - Attachments

    var pendingAttachments: [DraftAttachment] = []

    // MARK: - Groupchat

    var showParticipantSidebar = false

    var isGroupchat: Bool {
        conversation?.type == .groupchat
    }

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
            prefetchLinkPreviews()
            await environment.chatService.selectConversation(conv.id, accountID: accountID)
        } catch {
            // Conversation creation failed — leave state empty
        }
    }

    func refreshMessages() async {
        guard let conversationID = conversation?.id else { return }
        messages = await environment.chatService.loadMessages(for: conversationID)
        prefetchLinkPreviews()
    }

    func sendMessage(_ body: String) async {
        guard let accountID = environment.accountService.accounts.first?.id else { return }

        do {
            if isGroupchat {
                try await environment.chatService.sendGroupMessage(toJIDString: jidString, body: body, accountID: accountID)
            } else if let editing = editingMessage, let stanzaID = editing.stanzaID {
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

    func setRoomSubject(_ subject: String) async {
        guard let accountID = environment.accountService.accounts.first?.id else { return }
        try? await environment.chatService.setRoomSubject(jidString: jidString, subject: subject, accountID: accountID)
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

    // MARK: - Link Previews

    func linkPreview(for message: ChatMessage) -> LinkPreview? {
        guard let url = Self.extractFirstURL(from: message.body) else { return nil }
        return environment.linkPreviewService.cachedPreview(for: url)
    }

    private static let linkDetector: NSDataDetector = {
        do {
            return try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        } catch {
            fatalError("Failed to create link detector: \(error)")
        }
    }()

    private static func extractFirstURL(from body: String) -> String? {
        let range = NSRange(body.startIndex..., in: body)
        return linkDetector.firstMatch(in: body, range: range)?.url?.absoluteString
    }

    /// Fetches link previews for message URLs not yet in the in-memory cache.
    private func prefetchLinkPreviews() {
        let service = environment.linkPreviewService
        for message in messages {
            guard let urlString = Self.extractFirstURL(from: message.body),
                  service.cachedPreview(for: urlString) == nil,
                  let url = URL(string: urlString) else { continue }
            Task {
                _ = try? await service.fetchPreview(for: url)
            }
        }
    }

    // MARK: - Attachments

    func addAttachment(url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? Int64) ?? 0
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"

        let draft = DraftAttachment(
            url: url,
            fileName: url.lastPathComponent,
            fileSize: fileSize,
            mimeType: mimeType
        )
        pendingAttachments.append(draft)
    }

    func loadFileURL(from provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            let url: URL? = if let data = item as? Data {
                URL(dataRepresentation: data, relativeTo: nil)
            } else if let nsURL = item as? URL {
                nsURL
            } else {
                nil
            }
            guard let url else { return }
            Task { @MainActor in
                self.addAttachment(url: url)
            }
        }
    }

    func removeAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func clearAttachments() {
        pendingAttachments = []
    }

    func sendAttachments() async {
        guard let accountID = environment.accountService.accounts.first?.id else { return }
        guard let conversation else { return }

        let attachmentsToSend = pendingAttachments
        clearAttachments()

        for attachment in attachmentsToSend {
            do {
                try await environment.fileTransferService.sendFile(
                    url: attachment.url,
                    in: conversation,
                    accountID: accountID
                )
            } catch {
                // Transfer failed — tracked in FileTransferService.activeTransfers
            }
        }
    }
}
