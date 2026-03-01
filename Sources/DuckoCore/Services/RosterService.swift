import DuckoXMPP
import Foundation

@MainActor @Observable
public final class RosterService {
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

    // MARK: - Public API

    public func loadContacts(for accountID: UUID) async throws {
        let contacts = try await store.fetchContacts(for: accountID)
        groups = buildGroups(from: contacts)
    }

    public func addContact(jid: BareJID, name: String?, groups: [String], accountID: UUID) async throws {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let rosterModule = await client.module(ofType: RosterModule.self) else { return }
        try await rosterModule.addContact(jid: jid, name: name, groups: groups)
    }

    public func removeContact(_ contact: Contact, accountID: UUID) async throws {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let rosterModule = await client.module(ofType: RosterModule.self) else { return }
        try await rosterModule.removeContact(jid: contact.jid)
    }

    public func addContact(jidString: String, name: String?, groups: [String], accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else { return }
        try await addContact(jid: jid, name: name, groups: groups, accountID: accountID)
    }

    public func removeContact(jidString: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else { return }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let rosterModule = await client.module(ofType: RosterModule.self) else { return }
        try await rosterModule.removeContact(jid: jid)
    }

    public func approveSubscription(jidString: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else { return }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let rosterModule = await client.module(ofType: RosterModule.self) else { return }
        try await rosterModule.approveSubscription(from: jid)
        presenceService?.removeSubscriptionRequest(jid)
    }

    public func denySubscription(jidString: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else { return }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let rosterModule = await client.module(ofType: RosterModule.self) else { return }
        try await rosterModule.denySubscription(from: jid)
        presenceService?.removeSubscriptionRequest(jid)
    }

    public func fetchAvatars(accountID: UUID) async {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let vcardModule = await client.module(ofType: VCardModule.self) else { return }

        // Deduplicate contacts across groups
        var seen = Set<BareJID>()
        let uniqueContacts = groups.flatMap(\.contacts).filter { seen.insert($0.jid).inserted }

        for contact in uniqueContacts {
            guard contact.avatarData == nil else { continue }
            guard let vcard = try? await vcardModule.fetchVCard(for: contact.jid) else { continue }
            guard let photoData = vcard.photoData else { continue }

            var updated = contact
            updated.avatarData = Data(photoData)
            updated.avatarHash = vcard.photoHash
            try? await store.upsertContact(updated)
        }

        try? await loadContacts(for: accountID)
    }

    public func renameContact(_ contact: Contact, newAlias: String, accountID: UUID) async throws {
        var updated = contact
        updated.localAlias = newAlias.isEmpty ? nil : newAlias
        try await store.upsertContact(updated)
        try await loadContacts(for: accountID)
    }

    // MARK: - Event Handling

    func handleEvent(_ event: XMPPEvent, accountID: UUID) async {
        switch event {
        case let .rosterLoaded(items):
            await handleRosterLoaded(items, accountID: accountID)
        case let .rosterItemChanged(item):
            await handleRosterItemChanged(item, accountID: accountID)
        default:
            break
        }
    }

    // MARK: - Private

    private func handleRosterLoaded(_ items: [RosterItem], accountID: UUID) async {
        let existingContacts = await (try? store.fetchContacts(for: accountID)) ?? []

        // Build set of JIDs on the server roster
        let rosterJIDs = Set(items.map(\.jid))

        // Delete contacts no longer on roster
        for contact in existingContacts where !rosterJIDs.contains(contact.jid) {
            try? await store.deleteContact(contact.id)
        }

        // Upsert all roster items and collect results for group building
        var updatedContacts: [Contact] = []
        for item in items {
            let contact = mapRosterItem(item, accountID: accountID, existingContacts: existingContacts)
            try? await store.upsertContact(contact)
            updatedContacts.append(contact)
        }

        groups = buildGroups(from: updatedContacts)
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
        groups = buildGroups(from: contacts)
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

    private func buildGroups(from contacts: [Contact]) -> [ContactGroup] {
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

        // Sort contacts within each group by display name
        for key in grouped.keys {
            grouped[key]?.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }

        // Sort groups alphabetically, ContactGroup.ungroupedName last
        let sortedKeys = grouped.keys.sorted { lhs, rhs in
            if lhs == ContactGroup.ungroupedName { return false }
            if rhs == ContactGroup.ungroupedName { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

        return sortedKeys.map { key in
            ContactGroup(id: key, name: key, contacts: grouped[key] ?? [])
        }
    }
}
