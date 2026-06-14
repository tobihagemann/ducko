import DuckoXMPP
import Foundation

@MainActor @Observable
public final class RosterService {
    private var groupsByAccount: [UUID: [ContactGroup]] = [:]

    public var groups: [ContactGroup] {
        groupsByAccount.values.flatMap(\.self)
    }

    private let store: any PersistenceStore
    private weak var accountService: AccountService?
    private weak var presenceService: PresenceService?

    public init(store: any PersistenceStore) {
        self.store = store
    }

    // MARK: - Wiring

    func setAccountService(_ service: AccountService) {
        accountService = service
    }

    func setPresenceService(_ service: PresenceService) {
        presenceService = service
    }

    public enum RosterServiceError: Error, LocalizedError {
        case notConnected(UUID)
        case invalidJID(String)

        public var errorDescription: String? {
            switch self {
            case let .notConnected(id): notConnectedDescription(id)
            case let .invalidJID(string): "Invalid JID: \(string)"
            }
        }
    }

    // MARK: - Public API

    public func contact(jidString: String) -> Contact? {
        groups.lazy.flatMap(\.contacts).first { $0.jid.description == jidString }
    }

    /// Account-scoped lookup. Prefer this when the account is known: `contact(jidString:)`
    /// returns the first match across all accounts, so it resolves the wrong account when
    /// the same JID is on two.
    public func contact(jidString: String, accountID: UUID) -> Contact? {
        groupsByAccount[accountID]?.lazy.flatMap(\.contacts).first { $0.jid.description == jidString }
    }

    /// Accounts whose roster contains `jidString` (a bare JID), deduped so a contact appearing in
    /// multiple groups under one account is counted once. A duplicated JID — `count > 1` — drives
    /// the account indicator shown on roster rows and chat tabs.
    public func accountIDs(forBareJID jidString: String) -> Set<UUID> {
        var result: Set<UUID> = []
        for (accountID, groups) in groupsByAccount
            where groups.contains(where: { $0.contacts.contains { $0.jid.description == jidString } }) {
            result.insert(accountID)
        }
        return result
    }

    public func loadContacts(for accountID: UUID) async throws {
        let contacts = try await store.fetchContacts(for: accountID)
        groupsByAccount[accountID] = buildGroups(from: contacts, accountID: accountID)
    }

    public func addContact(jid: BareJID, name: String?, groups: [String], accountID: UUID) async throws {
        guard let client = accountService?.connectedClient(for: accountID) else { throw RosterServiceError.notConnected(accountID) }
        guard let rosterModule = await client.module(ofType: RosterModule.self) else { return }
        try await rosterModule.addContact(jid: jid, name: name, groups: groups)
        try await rosterModule.subscribe(to: jid)
    }

    public func removeContact(_ contact: Contact, accountID: UUID) async throws {
        guard let client = accountService?.connectedClient(for: accountID) else { throw RosterServiceError.notConnected(accountID) }
        guard let rosterModule = await client.module(ofType: RosterModule.self) else { return }
        try await rosterModule.removeContact(jid: contact.jid)
    }

    public func addContact(jidString: String, name: String?, groups: [String], accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else { throw RosterServiceError.invalidJID(jidString) }
        try await addContact(jid: jid, name: name, groups: groups, accountID: accountID)
    }

    public func removeContact(jidString: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else { throw RosterServiceError.invalidJID(jidString) }
        guard let client = accountService?.connectedClient(for: accountID) else { throw RosterServiceError.notConnected(accountID) }
        guard let rosterModule = await client.module(ofType: RosterModule.self) else { return }
        try await rosterModule.removeContact(jid: jid)
    }

    /// Sends a presence subscription request without touching the roster item. Use for a
    /// contact already in the roster (e.g. subscription `none`/`from`): `addContact` would
    /// send a roster set that overwrites the server-side name and groups.
    public func requestSubscription(jidString: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else { throw RosterServiceError.invalidJID(jidString) }
        guard let client = accountService?.connectedClient(for: accountID) else { throw RosterServiceError.notConnected(accountID) }
        guard let rosterModule = await client.module(ofType: RosterModule.self) else { return }
        try await rosterModule.subscribe(to: jid)
    }

    public func approveSubscription(jidString: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else { throw RosterServiceError.invalidJID(jidString) }
        guard let client = accountService?.connectedClient(for: accountID) else { throw RosterServiceError.notConnected(accountID) }
        guard let rosterModule = await client.module(ofType: RosterModule.self) else { return }
        try await rosterModule.approveSubscription(from: jid)
        presenceService?.removeSubscriptionRequest(jid, accountID: accountID)
    }

    public func denySubscription(jidString: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else { throw RosterServiceError.invalidJID(jidString) }
        guard let client = accountService?.connectedClient(for: accountID) else { throw RosterServiceError.notConnected(accountID) }
        guard let rosterModule = await client.module(ofType: RosterModule.self) else { return }
        try await rosterModule.denySubscription(from: jid)
        presenceService?.removeSubscriptionRequest(jid, accountID: accountID)
    }

    public func renameContact(_ contact: Contact, newAlias: String, accountID: UUID) async throws {
        var updated = contact
        updated.localAlias = newAlias.isEmpty ? nil : newAlias
        try await store.upsertContact(updated)
        try await loadContacts(for: accountID)
    }

    func updateLastSeen(jid: BareJID, date: Date, accountID: UUID) async {
        let contacts = await (try? store.fetchContacts(for: accountID)) ?? []
        guard let contact = contacts.first(where: { $0.jid == jid }) else { return }
        var updated = contact
        updated.lastSeen = date
        try? await store.upsertContact(updated)
        try? await loadContacts(for: accountID)
    }

    // MARK: - Blocking (XEP-0191)

    public func blockContact(jidString: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else { throw RosterServiceError.invalidJID(jidString) }
        guard let client = accountService?.connectedClient(for: accountID) else { throw RosterServiceError.notConnected(accountID) }
        guard let blockingModule = await client.module(ofType: BlockingModule.self) else { return }
        try await blockingModule.blockContact(jid: jid)
    }

    public func unblockContact(jidString: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else { throw RosterServiceError.invalidJID(jidString) }
        guard let client = accountService?.connectedClient(for: accountID) else { throw RosterServiceError.notConnected(accountID) }
        guard let blockingModule = await client.module(ofType: BlockingModule.self) else { return }
        try await blockingModule.unblockContact(jid: jid)
    }

    // MARK: - Event Handling

    func handleEvent(_ event: XMPPEvent, accountID: UUID) async {
        switch event {
        case let .rosterLoaded(items):
            await handleRosterLoaded(items, accountID: accountID)
        case let .rosterItemChanged(item):
            await handleRosterItemChanged(item, accountID: accountID)
        case let .rosterVersionChanged(version):
            await handleRosterVersionChanged(version, accountID: accountID)
        case let .blockListLoaded(jids):
            await handleBlockListLoaded(jids, accountID: accountID)
        case let .contactBlocked(jid):
            await handleBlockStateChanged(jid, isBlocked: true, accountID: accountID)
        case let .contactUnblocked(jid):
            await handleBlockStateChanged(jid, isBlocked: false, accountID: accountID)
        case let .presenceUpdated(from, presence):
            if presence.presenceType == .unavailable {
                await updateLastSeen(jid: from.bareJID, date: Date(), accountID: accountID)
            }
        case .disconnected:
            groupsByAccount.removeValue(forKey: accountID)
        case .connected, .streamResumed, .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged,
             .roomSubjectChanged, .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived,
             .roomDestroyed, .mucSelfPingFailed,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .jingleFileRequestReceived, .jingleChecksumReceived, .jingleChecksumMismatch,
             .jingleContentAddReceived, .jingleContentAccepted,
             .jingleContentRejected, .jingleContentRemoved,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced, .omemoRecipientsPartial,
             .oobIQOfferReceived, .serviceOutageReceived:
            break
        }
    }

    private func handleRosterLoaded(_ items: [RosterItem], accountID: UUID) async {
        let existingContacts = await (try? store.fetchContacts(for: accountID)) ?? []

        // Empty roster response with a cached version means "up-to-date" — use cached contacts
        if items.isEmpty {
            if !existingContacts.isEmpty {
                groupsByAccount[accountID] = buildGroups(from: existingContacts, accountID: accountID)
                return
            }
        }

        let rosterJIDs = Set(items.map(\.jid))

        for contact in existingContacts where !rosterJIDs.contains(contact.jid) {
            try? await store.deleteContact(contact.id)
        }

        var updatedContacts: [Contact] = []
        for item in items {
            let contact = mapRosterItem(item, accountID: accountID, existingContacts: existingContacts)
            try? await store.upsertContact(contact)
            updatedContacts.append(contact)
        }

        groupsByAccount[accountID] = buildGroups(from: updatedContacts, accountID: accountID)
    }

    private func handleRosterVersionChanged(_ version: String, accountID: UUID) async {
        guard var account = accountService?.accounts.first(where: { $0.id == accountID }) else { return }
        account.rosterVersion = version
        try? await store.saveAccount(account)
        try? await accountService?.loadAccounts()
    }

    private func handleRosterItemChanged(_ item: RosterItem, accountID: UUID) async {
        let existingContacts = await (try? store.fetchContacts(for: accountID)) ?? []

        if item.subscription == .remove {
            if let existing = existingContacts.first(where: { $0.jid == item.jid }) {
                try? await store.deleteContact(existing.id)
            }
        } else {
            let contact = mapRosterItem(item, accountID: accountID, existingContacts: existingContacts)
            try? await store.upsertContact(contact)
        }

        let contacts = await (try? store.fetchContacts(for: accountID)) ?? []
        groupsByAccount[accountID] = buildGroups(from: contacts, accountID: accountID)
    }

    private func mapRosterItem(_ item: RosterItem, accountID: UUID, existingContacts: [Contact]) -> Contact {
        let existing = existingContacts.first { $0.jid == item.jid }

        let subscription: Contact.Subscription = switch item.subscription {
        case .none: .none
        case .to: .to
        case .from: .from
        case .both: .both
        case .remove: .none
        }

        return Contact(
            id: existing?.id ?? UUID(),
            accountID: accountID,
            jid: item.jid,
            name: item.name,
            localAlias: existing?.localAlias,
            subscription: subscription,
            ask: item.ask ? "subscribe" : nil,
            groups: item.groups,
            avatarHash: existing?.avatarHash,
            avatarData: existing?.avatarData,
            isBlocked: existing?.isBlocked ?? false,
            lastSeen: existing?.lastSeen,
            createdAt: existing?.createdAt ?? Date()
        )
    }

    private func handleBlockListLoaded(_ jids: [BareJID], accountID: UUID) async {
        let contacts = await (try? store.fetchContacts(for: accountID)) ?? []
        let blockedSet = Set(jids)
        for contact in contacts {
            let shouldBeBlocked = blockedSet.contains(contact.jid)
            if contact.isBlocked != shouldBeBlocked {
                var updated = contact
                updated.isBlocked = shouldBeBlocked
                try? await store.upsertContact(updated)
            }
        }
        try? await loadContacts(for: accountID)
    }

    private func handleBlockStateChanged(_ jid: BareJID, isBlocked: Bool, accountID: UUID) async {
        let contacts = await (try? store.fetchContacts(for: accountID)) ?? []
        guard let contact = contacts.first(where: { $0.jid == jid }) else { return }
        var updated = contact
        updated.isBlocked = isBlocked
        try? await store.upsertContact(updated)
        try? await loadContacts(for: accountID)
    }

    private func buildGroups(from contacts: [Contact], accountID: UUID) -> [ContactGroup] {
        var grouped: [String: [Contact]] = [:]

        for contact in contacts {
            if contact.groups.isEmpty {
                grouped[ContactGroup.ungroupedName, default: []].append(contact)
            } else {
                for group in contact.groups {
                    grouped[group, default: []].append(contact)
                }
            }
        }

        for key in grouped.keys {
            grouped[key]?.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }

        // Sort groups alphabetically, ContactGroup.ungroupedName last
        let sortedKeys = grouped.keys.sorted { lhs, rhs in
            if lhs == ContactGroup.ungroupedName { return false }
            if rhs == ContactGroup.ungroupedName { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

        // Qualify the id with the account so the same group name on two accounts (e.g. "Ungrouped")
        // yields distinct `ContactGroup.id`s. `groups` flat-maps every account's groups into one
        // list; a shared id there is a duplicate `ForEach` identity that corrupts List selection
        // (selecting one same-JID row would select the other) and mis-targets per-group online counts.
        return sortedKeys.map { key in
            ContactGroup(id: "\(accountID.uuidString)|\(key)", name: key, contacts: grouped[key] ?? [])
        }
    }
}
