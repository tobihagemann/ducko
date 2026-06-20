import DuckoXMPP
import Foundation

@MainActor @Observable
public final class RosterService {
    /// Per-account groups. `groups` is the rebuilt merge of every slot, so a roster load on one
    /// account never drops another's. Source of truth behind the published merge — mutate slots
    /// through `setGroups`/`clearGroups` so the cache stays current.
    private var groupsByAccount: [UUID: [ContactGroup]] = [:]
    /// Load-generation counter, bumped on every `clearGroups(for:)`. A suspended roster-load handler
    /// captures the generation before its store read and re-checks it before publishing, so a teardown
    /// during the await can't resurrect a just-cleared account. Mirrors `OMEMOService.seenDeviceLoadGeneration`.
    private var groupsLoadGeneration: [UUID: UInt64] = [:]

    /// Per-account groups merged into one section per name (Adium-style), so a
    /// multi-account setup doesn't show duplicate same-named sections. Each row
    /// keeps its account-scoped selection identity via `Contact.accountID`, and the
    /// name is a safe `ForEach`/`onlineCounts` id because names are unique post-merge.
    /// Stored (not computed) so `@Observable` tracks it and the merge runs once per mutation, not per read.
    public private(set) var groups: [ContactGroup] = []

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
        let generationBeforeAwait = groupsLoadGeneration[accountID, default: 0]
        let contacts = try await store.fetchContacts(for: accountID)
        guard generationUnchanged(generationBeforeAwait, for: accountID) else { return }
        setGroups(buildGroups(from: contacts, accountID: accountID), for: accountID)
    }

    /// The current content generation for `accountID`. An external caller that mutates a contact and then
    /// refreshes the roster should capture this before its first `await`, re-check it before its own store
    /// write, and reload via `loadContacts(for:ifGenerationUnchangedSince:)` — so a `purgeAccount`/disconnect
    /// during the await can't republish a just-cleared account (plain `loadContacts` captures its own fresh
    /// generation, so an unguarded reload after an await is the hazard this prevents).
    public func contentGeneration(for accountID: UUID) -> UInt64 {
        groupsLoadGeneration[accountID, default: 0]
    }

    /// Reloads `accountID`'s contacts only if its content generation is unchanged since `captured`.
    public func loadContacts(for accountID: UUID, ifGenerationUnchangedSince captured: UInt64) async throws {
        guard generationUnchanged(captured, for: accountID) else { return }
        try await loadContacts(for: accountID)
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
        let generationBeforeAwait = groupsLoadGeneration[accountID, default: 0]
        var updated = contact
        updated.localAlias = newAlias.isEmpty ? nil : newAlias
        try await store.upsertContact(updated)
        // A purge during the upsert would otherwise let the follow-up loadContacts (fresh generation) republish.
        guard generationUnchanged(generationBeforeAwait, for: accountID) else { return }
        try await loadContacts(for: accountID)
    }

    func updateLastSeen(jid: BareJID, date: Date, accountID: UUID) async {
        let generationBeforeAwait = groupsLoadGeneration[accountID, default: 0]
        let contacts = await (try? store.fetchContacts(for: accountID)) ?? []
        guard let contact = contacts.first(where: { $0.jid == jid }) else { return }
        var updated = contact
        updated.lastSeen = date
        guard generationUnchanged(generationBeforeAwait, for: accountID) else { return }
        try? await store.upsertContact(updated)
        // A purge during the upsert would otherwise let the follow-up loadContacts (fresh generation) republish.
        guard generationUnchanged(generationBeforeAwait, for: accountID) else { return }
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
            clearGroups(for: accountID)
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
        let generationBeforeAwait = groupsLoadGeneration[accountID, default: 0]
        let existingContacts = await (try? store.fetchContacts(for: accountID)) ?? []

        // Empty roster response with a cached version means "up-to-date" — use cached contacts
        if items.isEmpty {
            if !existingContacts.isEmpty {
                guard generationUnchanged(generationBeforeAwait, for: accountID) else { return }
                setGroups(buildGroups(from: existingContacts, accountID: accountID), for: accountID)
                return
            }
        }

        let rosterJIDs = Set(items.map(\.jid))

        // Re-check between each write: a purge mid-loop would otherwise re-add rows after the account's deletion.
        for contact in existingContacts where !rosterJIDs.contains(contact.jid) {
            guard generationUnchanged(generationBeforeAwait, for: accountID) else { return }
            try? await store.deleteContact(contact.id)
        }

        var updatedContacts: [Contact] = []
        for item in items {
            guard generationUnchanged(generationBeforeAwait, for: accountID) else { return }
            let contact = mapRosterItem(item, accountID: accountID, existingContacts: existingContacts)
            try? await store.upsertContact(contact)
            updatedContacts.append(contact)
        }

        guard generationUnchanged(generationBeforeAwait, for: accountID) else { return }
        setGroups(buildGroups(from: updatedContacts, accountID: accountID), for: accountID)
    }

    private func handleRosterVersionChanged(_ version: String, accountID: UUID) async {
        guard var account = accountService?.accounts.first(where: { $0.id == accountID }) else { return }
        account.rosterVersion = version
        try? await store.saveAccount(account)
        try? await accountService?.loadAccounts()
    }

    private func handleRosterItemChanged(_ item: RosterItem, accountID: UUID) async {
        let generationBeforeAwait = groupsLoadGeneration[accountID, default: 0]
        let existingContacts = await (try? store.fetchContacts(for: accountID)) ?? []

        guard generationUnchanged(generationBeforeAwait, for: accountID) else { return }

        if item.subscription == .remove {
            if let existing = existingContacts.first(where: { $0.jid == item.jid }) {
                try? await store.deleteContact(existing.id)
            }
        } else {
            let contact = mapRosterItem(item, accountID: accountID, existingContacts: existingContacts)
            try? await store.upsertContact(contact)
        }

        let contacts = await (try? store.fetchContacts(for: accountID)) ?? []
        guard generationUnchanged(generationBeforeAwait, for: accountID) else { return }
        setGroups(buildGroups(from: contacts, accountID: accountID), for: accountID)
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
        let generationBeforeAwait = groupsLoadGeneration[accountID, default: 0]
        let contacts = await (try? store.fetchContacts(for: accountID)) ?? []
        let blockedSet = Set(jids)
        for contact in contacts {
            let shouldBeBlocked = blockedSet.contains(contact.jid)
            if contact.isBlocked != shouldBeBlocked {
                // Re-check before each write: a clear/purge during an earlier await tore the account down.
                guard generationUnchanged(generationBeforeAwait, for: accountID) else { return }
                var updated = contact
                updated.isBlocked = shouldBeBlocked
                try? await store.upsertContact(updated)
            }
        }
        // Re-check before the republish so a purge during the writes can't resurrect the account via loadContacts.
        guard generationUnchanged(generationBeforeAwait, for: accountID) else { return }
        try? await loadContacts(for: accountID)
    }

    private func handleBlockStateChanged(_ jid: BareJID, isBlocked: Bool, accountID: UUID) async {
        let generationBeforeAwait = groupsLoadGeneration[accountID, default: 0]
        let contacts = await (try? store.fetchContacts(for: accountID)) ?? []
        guard let contact = contacts.first(where: { $0.jid == jid }) else { return }
        var updated = contact
        updated.isBlocked = isBlocked
        guard generationUnchanged(generationBeforeAwait, for: accountID) else { return }
        try? await store.upsertContact(updated)
        // Re-check before the republish so a purge during the upsert can't resurrect the account via loadContacts.
        guard generationUnchanged(generationBeforeAwait, for: accountID) else { return }
        try? await loadContacts(for: accountID)
    }

    // MARK: - Lifecycle

    /// Drops one account's roster state on a lifecycle teardown that bypasses the `.disconnected`
    /// event handler (user-initiated `AccountService.disconnect`, account delete).
    func purgeAccount(_ accountID: UUID) {
        clearGroups(for: accountID)
    }

    // MARK: - Group Cache

    /// Replaces one account's groups slot and republishes the merge. The single landing point for a
    /// per-account roster result so cross-account derived reads stay current.
    private func setGroups(_ groups: [ContactGroup], for accountID: UUID) {
        groupsByAccount[accountID] = groups
        rebuildGroups()
    }

    /// Drops one account's groups slot, bumps the load generation so any in-flight load bails, and
    /// republishes the merge. Both the `.disconnected` handler and `purgeAccount` route through here.
    private func clearGroups(for accountID: UUID) {
        groupsByAccount.removeValue(forKey: accountID)
        groupsLoadGeneration[accountID, default: 0] &+= 1
        rebuildGroups()
    }

    /// True when no `clearGroups`/`purgeAccount` ran for `accountID` since `captured` was read — i.e. the
    /// account wasn't torn down during an intervening `store` await. A suspending handler captures the
    /// generation before its await and re-checks via this before any store mutation or cache publish, so a
    /// teardown can't resurrect a just-cleared account.
    private func generationUnchanged(_ captured: UInt64, for accountID: UUID) -> Bool {
        groupsLoadGeneration[accountID, default: 0] == captured
    }

    /// Rebuilds the published `groups` as the by-name merge of every account slot. Coalesces same-named
    /// per-account sections into one, sorted by `sortedGroupKeys` with contacts by display name.
    private func rebuildGroups() {
        var merged: [String: [Contact]] = [:]
        for accountGroups in groupsByAccount.values {
            for group in accountGroups {
                merged[group.name, default: []].append(contentsOf: group.contacts)
            }
        }
        groups = sortedGroupKeys(merged.keys).map { name in
            ContactGroup(id: name, name: name, contacts: sortedByDisplayName(merged[name] ?? []))
        }
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

        // Qualify the id with the account so the same group name on two accounts (e.g. "Ungrouped")
        // stays a distinct per-account `ContactGroup` here. The merged `groups` view coalesces these
        // by name into one section; the account-qualified id keeps the internal per-account lookups
        // (`groupsByAccount`) unambiguous.
        return sortedGroupKeys(grouped.keys).map { key in
            ContactGroup(id: "\(accountID.uuidString)|\(key)", name: key, contacts: sortedByDisplayName(grouped[key] ?? []))
        }
    }

    /// Contacts sorted by display name (case-insensitive) — the order both per-account
    /// `buildGroups` and the merged `groups` view present contacts in.
    private func sortedByDisplayName(_ contacts: [Contact]) -> [Contact] {
        contacts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Group names sorted alphabetically with `ContactGroup.ungroupedName` last. This order is
    /// the sole determinant of displayed section order: `ContactListFilter` sorts only contacts
    /// within groups and preserves the incoming group order, so the merged `groups` view sorts here.
    private func sortedGroupKeys(_ keys: some Sequence<String>) -> [String] {
        keys.sorted { lhs, rhs in
            if lhs == ContactGroup.ungroupedName { return false }
            if rhs == ContactGroup.ungroupedName { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }
}
