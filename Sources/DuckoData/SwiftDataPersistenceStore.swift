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

    public func fetchConversation(jid: String, type: Conversation.ConversationType, accountID: UUID?, importSourceJID: String?) throws -> Conversation? {
        let jidString = jid
        let typeString = type.rawValue
        var descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.jid == jidString && $0.type == typeString && $0.account?.id == accountID && $0.importSourceJID == importSourceJID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.toDomain()
    }

    public func fetchConversations(importSourceJID: String) throws -> [Conversation] {
        let sourceJID = importSourceJID
        let descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.importSourceJID == sourceJID }
        )
        return try modelContext.fetch(descriptor).compactMap { $0.toDomain() }
    }

    public func upsertConversation(_ conversation: Conversation) throws {
        let conversationID = conversation.id
        var descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.id == conversationID }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.update(from: conversation)
            // Update account relationship if changed (e.g., auto-linking imported conversations)
            if existing.account?.id != conversation.accountID {
                if let accountID = conversation.accountID {
                    var accountDescriptor = FetchDescriptor<AccountRecord>(
                        predicate: #Predicate { $0.id == accountID }
                    )
                    accountDescriptor.fetchLimit = 1
                    existing.account = try modelContext.fetch(accountDescriptor).first
                } else {
                    existing.account = nil
                }
            }
        } else {
            var accountRecord: AccountRecord?
            if let accountID = conversation.accountID {
                var accountDescriptor = FetchDescriptor<AccountRecord>(
                    predicate: #Predicate { $0.id == accountID }
                )
                accountDescriptor.fetchLimit = 1
                guard let record = try modelContext.fetch(accountDescriptor).first else {
                    throw PersistenceStoreError.parentNotFound("AccountRecord(\(accountID))")
                }
                accountRecord = record
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
                importSourceJID: conversation.importSourceJID,
                roomSubject: conversation.roomSubject,
                roomNickname: conversation.roomNickname,
                lastReadTimestamp: conversation.lastReadTimestamp,
                createdAt: conversation.createdAt
            )
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    public func fetchAllConversations() throws -> [Conversation] {
        let descriptor = FetchDescriptor<ConversationRecord>(
            sortBy: [SortDescriptor(\.lastMessageDate, order: .reverse)]
        )
        let records = try modelContext.fetch(descriptor)
        return records.compactMap { $0.toDomain() }
    }

    public func markConversationRead(_ conversationID: UUID) throws {
        var descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.id == conversationID }
        )
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            record.unreadCount = 0
            record.lastReadTimestamp = Date()
            try modelContext.save()
        }
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
