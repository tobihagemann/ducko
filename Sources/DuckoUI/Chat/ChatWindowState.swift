import DuckoCore
import Logging
import SwiftUI
import UniformTypeIdentifiers

private let log = Logger(label: "im.ducko.ui.chatwindow")

@MainActor @Observable
final class ChatWindowState {
    var conversation: Conversation?
    var contact: Contact?
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

    var myRoomRole: RoomRole? {
        guard isGroupchat,
              let nickname = conversation?.roomNickname else { return nil }
        let participants = environment.chatService.roomParticipants[jidString] ?? []
        return participants.first { $0.nickname == nickname }?.role
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
            let conv: Conversation
            if let slashIndex = jidString.firstIndex(of: "/"),
               jidString[..<slashIndex].contains("@") {
                // MUC PM: "room@conference/nick"
                let roomJIDString = String(jidString[..<slashIndex])
                let nickname = String(jidString[jidString.index(after: slashIndex)...])
                conv = try await environment.chatService.openMUCPMConversation(
                    roomJIDString: roomJIDString, nickname: nickname, accountID: accountID
                )
            } else {
                conv = try await environment.chatService.openConversation(jidString: jidString, accountID: accountID)
                contact = environment.rosterService.contact(jidString: jidString)
            }
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
            if isGroupchat, let editing = editingMessage, let stanzaID = editing.stanzaID {
                try await environment.chatService.sendGroupCorrection(
                    originalStanzaID: stanzaID,
                    newBody: body,
                    inRoomJIDString: jidString,
                    accountID: accountID
                )
            } else if isGroupchat {
                try await environment.chatService.sendGroupMessage(toJIDString: jidString, body: body, accountID: accountID)
            } else if let conv = conversation, let nick = conv.occupantNickname {
                try await environment.chatService.sendMUCPrivateMessage(
                    roomJIDString: conv.jid.description,
                    nickname: nick, body: body, accountID: accountID
                )
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

    // MARK: - Retraction

    func retractMessage(_ message: ChatMessage) async {
        guard let accountID = environment.accountService.accounts.first?.id,
              let stanzaID = message.stanzaID else { return }

        do {
            if isGroupchat {
                try await environment.chatService.retractGroupMessage(stanzaID: stanzaID, inRoomJIDString: jidString, accountID: accountID)
            } else {
                try await environment.chatService.retractMessage(stanzaID: stanzaID, toJIDString: jidString, accountID: accountID)
            }
            await refreshMessages()
        } catch {
            log.warning("Failed to retract message: \(error)")
        }
    }

    // MARK: - Moderation

    func moderateMessage(_ message: ChatMessage, reason: String?) async {
        guard let accountID = environment.accountService.accounts.first?.id,
              let serverID = message.serverID else { return }

        do {
            try await environment.chatService.moderateMessage(
                serverID: serverID, inRoomJIDString: jidString, reason: reason, accountID: accountID
            )
            await refreshMessages()
        } catch {
            log.warning("Failed to moderate message: \(error)")
        }
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
                // Local store exhausted — try server
                guard let accountID = environment.accountService.accounts.first?.id else {
                    hasReachedEnd = true
                    return
                }
                let (serverMessages, hasMore) = try await environment.chatService.fetchServerHistory(
                    jidString: jidString,
                    accountID: accountID,
                    before: messages.first?.timestamp,
                    limit: 50
                )
                if serverMessages.isEmpty {
                    hasReachedEnd = true
                } else {
                    messages = serverMessages + messages
                    if !hasMore {
                        hasReachedEnd = true
                    }
                }
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
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"

        let draft = DraftAttachment(
            url: url,
            fileName: url.lastPathComponent,
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
