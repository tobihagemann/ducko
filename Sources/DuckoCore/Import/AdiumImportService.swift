import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.import")

/// Orchestrates importing Adium chat logs into Ducko's persistence store.
public actor AdiumImportService {
    private let store: any PersistenceStore

    public init(store: any PersistenceStore) {
        self.store = store
    }

    // MARK: - Progress

    public struct ImportProgress: Sendable {
        public var totalFiles: Int
        public var completedFiles: Int
        public var importedMessages: Int
        public var skippedDuplicates: Int
        public var errors: [ImportError]

        public init(totalFiles: Int, completedFiles: Int, importedMessages: Int, skippedDuplicates: Int, errors: [ImportError]) {
            self.totalFiles = totalFiles
            self.completedFiles = completedFiles
            self.importedMessages = importedMessages
            self.skippedDuplicates = skippedDuplicates
            self.errors = errors
        }
    }

    public struct ImportError: Sendable {
        public let file: String
        public let message: String

        public init(file: String, message: String) {
            self.file = file
            self.message = message
        }
    }

    // MARK: - Import

    // swiftlint:disable cyclomatic_complexity function_body_length
    /// Imports Adium logs from the discovered service accounts.
    public func importLogs(
        from sources: [AdiumServiceAccount],
        progress: @Sendable (ImportProgress) -> Void
    ) async throws -> ImportProgress {
        let totalFiles = sources.reduce(0) { $0 + $1.fileCount }
        var result = ImportProgress(
            totalFiles: totalFiles,
            completedFiles: 0,
            importedMessages: 0,
            skippedDuplicates: 0,
            errors: []
        )

        for source in sources {
            let account = try await findOrCreateAccount(for: source)

            for contactDir in source.contactDirectories {
                let contactUID = contactDir.lastPathComponent
                let logFiles: [URL]
                do {
                    logFiles = try AdiumLogDiscovery.logFileURLs(in: contactDir)
                } catch {
                    log.warning("Failed to enumerate logs in \(contactDir.path): \(error)")
                    continue
                }

                // Cache conversation for this contact
                var conversation: Conversation?

                for fileURL in logFiles {
                    try Task.checkCancellation()

                    do {
                        let parsed = try parseLogFile(at: fileURL, accountUID: source.accountUID)

                        guard !parsed.entries.isEmpty else {
                            result.completedFiles += 1
                            continue
                        }

                        // Determine chat type from first file if not yet resolved
                        if conversation == nil {
                            let isGroupchat = detectGroupchat(entries: parsed.entries, accountUID: source.accountUID)
                            let chatType: Conversation.ConversationType = isGroupchat ? .groupchat : .chat
                            let jidString = syntheticJID(identifier: contactUID, service: source.service)

                            if let existing = try await store.fetchConversation(jid: jidString, type: chatType, accountID: account.id) {
                                conversation = existing
                            } else {
                                guard let bareJID = BareJID.parse(jidString) else {
                                    result.errors.append(ImportError(file: contactDir.path, message: "Invalid JID: \(jidString)"))
                                    result.completedFiles += logFiles.count
                                    break
                                }
                                let conv = Conversation(
                                    id: UUID(),
                                    accountID: account.id,
                                    jid: bareJID,
                                    type: chatType,
                                    displayName: contactUID,
                                    isPinned: false,
                                    isMuted: false,
                                    unreadCount: 0,
                                    createdAt: Date()
                                )
                                try await store.upsertConversation(conv)
                                conversation = conv
                            }
                        }

                        guard let conv = conversation else { continue }

                        // Build messages and check for duplicates
                        let messages = parsed.entries.enumerated().map { index, entry in
                            let stanzaID = AdiumXMLLogParser.stanzaID(sourcePath: parsed.sourcePath, messageIndex: index)
                            let isOutgoing = isOutgoingMessage(entry: entry, accountUID: source.accountUID)
                            let fromJID: String = if conv.type == .groupchat, let slashIndex = entry.sender.firstIndex(of: "/") {
                                String(entry.sender[entry.sender.index(after: slashIndex)...])
                            } else {
                                entry.sender
                            }

                            return ChatMessage(
                                id: UUID(),
                                conversationID: conv.id,
                                stanzaID: stanzaID,
                                fromJID: fromJID,
                                body: entry.body,
                                htmlBody: entry.htmlBody,
                                timestamp: entry.timestamp,
                                isOutgoing: isOutgoing,
                                isRead: true,
                                isDelivered: true,
                                isEdited: false,
                                type: conv.type.rawValue
                            )
                        }

                        let allStanzaIDs = Set(messages.compactMap(\.stanzaID))
                        let existingIDs = try await store.existingStanzaIDs(allStanzaIDs, in: conv.id)
                        let newMessages = messages.filter { msg in
                            guard let sid = msg.stanzaID else { return true }
                            return !existingIDs.contains(sid)
                        }

                        result.skippedDuplicates += messages.count - newMessages.count

                        if !newMessages.isEmpty {
                            try await store.insertMessages(newMessages)
                            result.importedMessages += newMessages.count

                            // Update conversation last message
                            if let lastMessage = newMessages.max(by: { $0.timestamp < $1.timestamp }) {
                                if lastMessage.timestamp > (conv.lastMessageDate ?? .distantPast) {
                                    var updated = conv
                                    updated.lastMessageDate = lastMessage.timestamp
                                    updated.lastMessagePreview = String(lastMessage.body.prefix(100))
                                    try await store.upsertConversation(updated)
                                    conversation = updated
                                }
                            }
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        result.errors.append(ImportError(file: fileURL.path, message: error.localizedDescription))
                        log.warning("Failed to import \(fileURL.lastPathComponent): \(error)")
                    }

                    result.completedFiles += 1
                    if result.completedFiles % 50 == 0 {
                        progress(result)
                    }
                }
            }
        }

        progress(result)
        log.info("Import complete: \(result.importedMessages) messages imported, \(result.skippedDuplicates) duplicates skipped, \(result.errors.count) errors")
        return result
    }

    // swiftlint:enable cyclomatic_complexity function_body_length

    // MARK: - Private

    /// Cache of resolved accounts by JID string to avoid repeated fetchAccounts calls.
    private var accountCache: [String: Account] = [:]

    private func findOrCreateAccount(for source: AdiumServiceAccount) async throws -> Account {
        let jidString = syntheticJID(identifier: source.accountUID, service: source.service)

        if let cached = accountCache[jidString] {
            return cached
        }

        // Check if account already exists in the store
        let accounts = try await store.fetchAccounts()
        if let existing = accounts.first(where: { $0.jid.description == jidString }) {
            accountCache[jidString] = existing
            return existing
        }

        guard let bareJID = BareJID.parse(jidString) else {
            throw ImportServiceError.invalidAccountJID(jidString)
        }

        let account = Account(
            id: UUID(),
            jid: bareJID,
            displayName: "\(source.service) (\(source.accountUID))",
            isEnabled: false,
            connectOnLaunch: false,
            importedFrom: "adium",
            createdAt: Date()
        )
        try await store.saveAccount(account)
        accountCache[jidString] = account
        log.info("Created placeholder account for \(source.service).\(source.accountUID)")
        return account
    }

    private func parseLogFile(at url: URL, accountUID: String) throws -> AdiumLogFile {
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()

        let entries: [AdiumLogEntry]
        switch ext {
        case "xml":
            entries = AdiumXMLLogParser.parse(data: data)
        case "html", "adiumhtmllog":
            let fileDate = AdiumHTMLLogParser.dateFromFilename(url.lastPathComponent) ?? Date()
            entries = AdiumHTMLLogParser.parse(data: data, fileDate: fileDate, accountUID: accountUID)
        default:
            entries = []
        }

        return AdiumLogFile(entries: entries, sourcePath: url.path)
    }

    private func detectGroupchat(entries: [AdiumLogEntry], accountUID _: String) -> Bool {
        // MUC messages have sender format "room@conference/nickname"
        entries.contains { entry in
            guard entry.sender.contains("/") else { return false }
            let parts = entry.sender.split(separator: "/", maxSplits: 1)
            return parts.count == 2 && parts[0].contains("@")
        }
    }

    private func isOutgoingMessage(entry: AdiumLogEntry, accountUID: String) -> Bool {
        // For XMPP: sender matches account JID
        // For MUC: sender resource matches account nickname (approximation)
        if entry.sender == accountUID { return true }
        if entry.sender.hasPrefix(accountUID) { return true }
        // For MUC, check if alias matches account (Adium often uses account UID as alias)
        if let alias = entry.alias, alias == accountUID { return true }
        return false
    }

    func syntheticJID(identifier: String, service: String) -> String {
        let normalizedService = service.lowercased()
        // Jabber and GTalk accounts already have valid JIDs
        switch normalizedService {
        case "jabber", "gtalk":
            return identifier
        default:
            return "\(identifier)@\(normalizedService).adium-import"
        }
    }
}

// MARK: - Errors

enum ImportServiceError: Error, LocalizedError {
    case invalidAccountJID(String)

    var errorDescription: String? {
        switch self {
        case let .invalidAccountJID(jid):
            "Invalid account JID: \(jid)"
        }
    }
}
