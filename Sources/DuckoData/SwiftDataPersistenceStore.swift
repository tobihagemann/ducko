import DuckoCore
import DuckoXMPP
import Foundation
import SwiftData

enum PersistenceStoreError: Error {
    case parentNotFound(String)
}

@ModelActor
public actor SwiftDataPersistenceStore: PersistenceStore {
    // MARK: - Accounts

    public func fetchAccounts() throws -> [Account] {
        let descriptor = FetchDescriptor<AccountRecord>(sortBy: [SortDescriptor(\.createdAt)])
        let records = try modelContext.fetch(descriptor)
        return records.compactMap { $0.toDomain() }
    }

    public func saveAccount(_ account: Account) throws {
        let accountID = account.id
        var descriptor = FetchDescriptor<AccountRecord>(
            predicate: #Predicate { $0.id == accountID }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.update(from: account)
        } else {
            let record = AccountRecord(
                id: account.id,
                jid: account.jid.description,
                displayName: account.displayName,
                isEnabled: account.isEnabled,
                connectOnLaunch: account.connectOnLaunch,
                host: account.host,
                port: account.port,
                resource: account.resource,
                requireTLS: account.requireTLS,
                rosterVersion: account.rosterVersion,
                createdAt: account.createdAt
            )
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    public func deleteAccount(_ id: UUID) throws {
        var descriptor = FetchDescriptor<AccountRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1

        if let record = try modelContext.fetch(descriptor).first {
            modelContext.delete(record)
            try modelContext.save()
        }
    }

    // MARK: - Contacts

    public func fetchContacts(for accountID: UUID) throws -> [Contact] {
        let descriptor = FetchDescriptor<ContactRecord>(
            predicate: #Predicate { $0.account?.id == accountID },
            sortBy: [SortDescriptor(\.jid)]
        )
        let records = try modelContext.fetch(descriptor)
        return records.compactMap { $0.toDomain() }
    }

    public func upsertContact(_ contact: Contact) throws {
        let contactID = contact.id
        var descriptor = FetchDescriptor<ContactRecord>(
            predicate: #Predicate { $0.id == contactID }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.update(from: contact)
        } else {
            let accountID = contact.accountID
            var accountDescriptor = FetchDescriptor<AccountRecord>(
                predicate: #Predicate { $0.id == accountID }
            )
            accountDescriptor.fetchLimit = 1
            guard let accountRecord = try modelContext.fetch(accountDescriptor).first else {
                throw PersistenceStoreError.parentNotFound("AccountRecord(\(accountID))")
            }

            let record = ContactRecord(
                id: contact.id,
                jid: contact.jid.description,
                name: contact.name,
                localAlias: contact.localAlias,
                subscription: contact.subscription.rawValue,
                ask: contact.ask,
                groups: contact.groups,
                avatarHash: contact.avatarHash,
                avatarData: contact.avatarData,
                isBlocked: contact.isBlocked,
                account: accountRecord,
                lastSeen: contact.lastSeen,
                createdAt: contact.createdAt
            )
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    public func deleteContact(_ id: UUID) throws {
        var descriptor = FetchDescriptor<ContactRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1

        if let record = try modelContext.fetch(descriptor).first {
            modelContext.delete(record)
            try modelContext.save()
        }
    }

    // MARK: - Conversations

    public func fetchConversations(for accountID: UUID) throws -> [Conversation] {
        let descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.account?.id == accountID },
            sortBy: [SortDescriptor(\.lastMessageDate, order: .reverse)]
        )
        let records = try modelContext.fetch(descriptor)
        return records.compactMap { $0.toDomain() }
    }

    public func fetchConversation(jid: String, type: Conversation.ConversationType, accountID: UUID) throws -> Conversation? {
        let jidString = jid
        let typeString = type.rawValue
        var descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.jid == jidString && $0.type == typeString && $0.account?.id == accountID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.toDomain()
    }

    public func upsertConversation(_ conversation: Conversation) throws {
        let conversationID = conversation.id
        var descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.id == conversationID }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.update(from: conversation)
        } else {
            let accountID = conversation.accountID
            var accountDescriptor = FetchDescriptor<AccountRecord>(
                predicate: #Predicate { $0.id == accountID }
            )
            accountDescriptor.fetchLimit = 1
            guard let accountRecord = try modelContext.fetch(accountDescriptor).first else {
                throw PersistenceStoreError.parentNotFound("AccountRecord(\(accountID))")
            }

            let record = ConversationRecord(
                id: conversation.id,
                jid: conversation.jid.description,
                type: conversation.type.rawValue,
                displayName: conversation.displayName,
                isPinned: conversation.isPinned,
                isMuted: conversation.isMuted,
                lastMessageDate: conversation.lastMessageDate,
                lastMessagePreview: conversation.lastMessagePreview,
                unreadCount: conversation.unreadCount,
                account: accountRecord,
                roomSubject: conversation.roomSubject,
                roomNickname: conversation.roomNickname,
                createdAt: conversation.createdAt
            )
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    // MARK: - Messages

    public func fetchMessages(
        for conversationID: UUID, before: Date?, limit: Int
    ) throws -> [ChatMessage] {
        var descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate {
                $0.conversation?.id == conversationID
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        if let before {
            descriptor = FetchDescriptor<MessageRecord>(
                predicate: #Predicate {
                    $0.conversation?.id == conversationID && $0.timestamp < before
                },
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
        }
        descriptor.fetchLimit = limit

        let records = try modelContext.fetch(descriptor)
        return records.compactMap { $0.toDomain() }
    }

    public func insertMessage(_ message: ChatMessage) throws {
        let conversationID = message.conversationID
        var conversationDescriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.id == conversationID }
        )
        conversationDescriptor.fetchLimit = 1
        guard let conversationRecord = try modelContext.fetch(conversationDescriptor).first else {
            throw PersistenceStoreError.parentNotFound("ConversationRecord(\(conversationID))")
        }

        let record = MessageRecord(
            id: message.id,
            stanzaID: message.stanzaID,
            serverID: message.serverID,
            fromJID: message.fromJID,
            body: message.body,
            htmlBody: message.htmlBody,
            timestamp: message.timestamp,
            isOutgoing: message.isOutgoing,
            isRead: message.isRead,
            isDelivered: message.isDelivered,
            isEdited: message.isEdited,
            editedAt: message.editedAt,
            type: message.type,
            conversation: conversationRecord,
            attachments: message.attachments.map { attachment in
                AttachmentRecord(
                    id: attachment.id,
                    url: attachment.url,
                    mimeType: attachment.mimeType,
                    fileName: attachment.fileName,
                    fileSize: attachment.fileSize,
                    thumbnailData: attachment.thumbnailData,
                    oobDescription: attachment.oobDescription
                )
            },
            replyToID: message.replyToID,
            errorText: message.errorText,
            isEncrypted: message.isEncrypted
        )
        modelContext.insert(record)
        try modelContext.save()
    }

    public func fetchMessageByStanzaID(_ stanzaID: String) throws -> ChatMessage? {
        var descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.stanzaID == stanzaID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.toDomain()
    }

    public func messageExistsByServerID(_ serverID: String, conversationID: UUID) throws -> Bool {
        var descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate {
                $0.serverID == serverID && $0.conversation?.id == conversationID
            }
        )
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    public func messageExistsByStanzaID(_ stanzaID: String, conversationID: UUID) throws -> Bool {
        var descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate {
                $0.stanzaID == stanzaID && $0.conversation?.id == conversationID
            }
        )
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    public func markMessagesRead(in conversationID: UUID) throws {
        let messageDescriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate {
                $0.conversation?.id == conversationID && $0.isRead == false
            }
        )
        let unreadMessages = try modelContext.fetch(messageDescriptor)
        for message in unreadMessages {
            message.isRead = true
        }

        var conversationDescriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.id == conversationID }
        )
        conversationDescriptor.fetchLimit = 1
        if let conversation = try modelContext.fetch(conversationDescriptor).first {
            conversation.unreadCount = 0
        }

        try modelContext.save()
    }

    // MARK: - Message Updates

    public func updateMessageDeliveryStatus(stanzaID: String, isDelivered: Bool) throws {
        var descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.stanzaID == stanzaID }
        )
        descriptor.fetchLimit = 1

        if let record = try modelContext.fetch(descriptor).first {
            record.isDelivered = isDelivered
            try modelContext.save()
        }
    }

    public func updateMessageBody(stanzaID: String, newBody: String, isEdited: Bool, editedAt: Date) throws {
        var descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.stanzaID == stanzaID }
        )
        descriptor.fetchLimit = 1

        if let record = try modelContext.fetch(descriptor).first {
            record.body = newBody
            record.htmlBody = nil
            record.isEdited = isEdited
            record.editedAt = editedAt
            try modelContext.save()
        }
    }

    public func updateMessageError(stanzaID: String, errorText: String) throws {
        var descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.stanzaID == stanzaID }
        )
        descriptor.fetchLimit = 1

        if let record = try modelContext.fetch(descriptor).first {
            record.errorText = errorText
            try modelContext.save()
        }
    }

    public func markMessageRetracted(stanzaID: String, retractedAt: Date) throws {
        var descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.stanzaID == stanzaID }
        )
        descriptor.fetchLimit = 1
        try applyRetraction(descriptor: descriptor, retractedAt: retractedAt)
    }

    public func markMessageRetractedByServerID(_ serverID: String, retractedAt: Date) throws {
        var descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.serverID == serverID }
        )
        descriptor.fetchLimit = 1
        try applyRetraction(descriptor: descriptor, retractedAt: retractedAt)
    }

    private func applyRetraction(descriptor: FetchDescriptor<MessageRecord>, retractedAt: Date) throws {
        if let record = try modelContext.fetch(descriptor).first {
            record.isRetracted = true
            record.retractedAt = retractedAt
            record.body = ""
            record.htmlBody = nil
            try modelContext.save()
        }
    }

    // MARK: - Batch Operations (Import)

    // swiftlint:disable:next function_body_length
    public func insertMessages(_ messages: [ChatMessage]) throws {
        guard !messages.isEmpty else { return }

        // Cache conversation record lookups by ID
        var conversationCache: [UUID: ConversationRecord] = [:]

        for message in messages {
            let conversationID = message.conversationID
            let conversationRecord: ConversationRecord
            if let cached = conversationCache[conversationID] {
                conversationRecord = cached
            } else {
                var descriptor = FetchDescriptor<ConversationRecord>(
                    predicate: #Predicate { $0.id == conversationID }
                )
                descriptor.fetchLimit = 1
                guard let record = try modelContext.fetch(descriptor).first else {
                    throw PersistenceStoreError.parentNotFound("ConversationRecord(\(conversationID))")
                }
                conversationCache[conversationID] = record
                conversationRecord = record
            }

            let record = MessageRecord(
                id: message.id,
                stanzaID: message.stanzaID,
                serverID: message.serverID,
                fromJID: message.fromJID,
                body: message.body,
                htmlBody: message.htmlBody,
                timestamp: message.timestamp,
                isOutgoing: message.isOutgoing,
                isRead: message.isRead,
                isDelivered: message.isDelivered,
                isEdited: message.isEdited,
                editedAt: message.editedAt,
                type: message.type,
                conversation: conversationRecord,
                attachments: message.attachments.map { attachment in
                    AttachmentRecord(
                        id: attachment.id,
                        url: attachment.url,
                        mimeType: attachment.mimeType,
                        fileName: attachment.fileName,
                        fileSize: attachment.fileSize,
                        thumbnailData: attachment.thumbnailData,
                        oobDescription: attachment.oobDescription
                    )
                },
                replyToID: message.replyToID,
                errorText: message.errorText,
                isEncrypted: message.isEncrypted
            )
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    public func existingStanzaIDs(_ stanzaIDs: Set<String>, in conversationID: UUID) throws -> Set<String> {
        let descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate {
                $0.conversation?.id == conversationID && $0.stanzaID != nil
            }
        )
        let records = try modelContext.fetch(descriptor)
        let existing = Set(records.compactMap(\.stanzaID))
        return existing.intersection(stanzaIDs)
    }

    // MARK: - Cross-Conversation Queries (Transcripts)

    public func fetchAllConversations() throws -> [Conversation] {
        let descriptor = FetchDescriptor<ConversationRecord>(
            sortBy: [SortDescriptor(\.lastMessageDate, order: .reverse)]
        )
        let records = try modelContext.fetch(descriptor)
        return records.compactMap { $0.toDomain() }
    }

    // swiftlint:disable:next function_body_length - SwiftData #Predicate requires separate branches for each optional combination
    public func searchMessages(query: String, conversationID: UUID?, before: Date?, after: Date?, limit: Int) throws -> [ChatMessage] {
        var descriptor = if let conversationID {
            if let before, let after {
                FetchDescriptor<MessageRecord>(
                    predicate: #Predicate {
                        $0.conversation?.id == conversationID &&
                            $0.body.localizedStandardContains(query) &&
                            $0.timestamp < before && $0.timestamp > after
                    },
                    sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
                )
            } else if let before {
                FetchDescriptor<MessageRecord>(
                    predicate: #Predicate {
                        $0.conversation?.id == conversationID &&
                            $0.body.localizedStandardContains(query) &&
                            $0.timestamp < before
                    },
                    sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
                )
            } else if let after {
                FetchDescriptor<MessageRecord>(
                    predicate: #Predicate {
                        $0.conversation?.id == conversationID &&
                            $0.body.localizedStandardContains(query) &&
                            $0.timestamp > after
                    },
                    sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
                )
            } else {
                FetchDescriptor<MessageRecord>(
                    predicate: #Predicate {
                        $0.conversation?.id == conversationID &&
                            $0.body.localizedStandardContains(query)
                    },
                    sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
                )
            }
        } else {
            if let before, let after {
                FetchDescriptor<MessageRecord>(
                    predicate: #Predicate {
                        $0.body.localizedStandardContains(query) &&
                            $0.timestamp < before && $0.timestamp > after
                    },
                    sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
                )
            } else if let before {
                FetchDescriptor<MessageRecord>(
                    predicate: #Predicate {
                        $0.body.localizedStandardContains(query) &&
                            $0.timestamp < before
                    },
                    sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
                )
            } else if let after {
                FetchDescriptor<MessageRecord>(
                    predicate: #Predicate {
                        $0.body.localizedStandardContains(query) &&
                            $0.timestamp > after
                    },
                    sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
                )
            } else {
                FetchDescriptor<MessageRecord>(
                    predicate: #Predicate {
                        $0.body.localizedStandardContains(query)
                    },
                    sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
                )
            }
        }
        descriptor.fetchLimit = limit

        let records = try modelContext.fetch(descriptor)
        return records.compactMap { $0.toDomain() }
    }

    // periphery:ignore - infrastructure for transcript viewer detail pane (not wired up yet)
    public func messageCount(for conversationID: UUID) throws -> Int {
        let descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.conversation?.id == conversationID }
        )
        return try modelContext.fetchCount(descriptor)
    }

    // periphery:ignore - infrastructure for transcript viewer detail pane (not wired up yet)
    public func messageDateRange(for conversationID: UUID) throws -> (earliest: Date, latest: Date)? {
        var earliestDescriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.conversation?.id == conversationID },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        earliestDescriptor.fetchLimit = 1

        var latestDescriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.conversation?.id == conversationID },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        latestDescriptor.fetchLimit = 1

        guard let earliest = try modelContext.fetch(earliestDescriptor).first?.timestamp,
              let latest = try modelContext.fetch(latestDescriptor).first?.timestamp else {
            return nil
        }
        return (earliest, latest)
    }

    // MARK: - Link Previews

    public func fetchLinkPreview(for url: String) throws -> LinkPreview? {
        var descriptor = FetchDescriptor<LinkPreviewRecord>(
            predicate: #Predicate { $0.url == url }
        )
        descriptor.fetchLimit = 1

        return try modelContext.fetch(descriptor).first?.toDomain()
    }

    public func upsertLinkPreview(_ preview: LinkPreview) throws {
        let previewURL = preview.url
        var descriptor = FetchDescriptor<LinkPreviewRecord>(
            predicate: #Predicate { $0.url == previewURL }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.update(from: preview)
        } else {
            let record = LinkPreviewRecord(
                url: preview.url,
                title: preview.title,
                descriptionText: preview.descriptionText,
                imageURL: preview.imageURL,
                siteName: preview.siteName,
                fetchedAt: preview.fetchedAt
            )
            modelContext.insert(record)
        }
        try modelContext.save()
    }
}
