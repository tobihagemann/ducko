import DuckoXMPP
import Foundation
import os

private let log = Logger(subsystem: "com.ducko.core", category: "avatar")

/// Avatar fetch result containing image data, hash, and MIME type.
public struct AvatarData: Sendable {
    public let data: Data
    public let hash: String
    public let mimeType: String

    public init(data: Data, hash: String, mimeType: String) {
        self.data = data
        self.hash = hash
        self.mimeType = mimeType
    }
}

@MainActor @Observable
public final class AvatarService {
    /// Whether the server supports XEP-0398 PEP-to-vCard conversion.
    private var serverSupportsConversion: Bool = false
    /// Own avatar hash (for presence broadcasts).
    public private(set) var ownAvatarHash: String?

    private weak var accountService: AccountService?
    private weak var rosterService: RosterService?
    private weak var presenceService: PresenceService?
    private let store: any PersistenceStore

    public init(store: any PersistenceStore) {
        self.store = store
    }

    // MARK: - Wiring

    func setAccountService(_ service: AccountService) {
        accountService = service
    }

    func setRosterService(_ service: RosterService) {
        rosterService = service
    }

    func setPresenceService(_ service: PresenceService) {
        presenceService = service
    }

    // MARK: - Event Handling

    func handleEvent(_ event: XMPPEvent, accountID: UUID) async {
        switch event {
        case .connected:
            await handleConnected(accountID: accountID)
        case let .pepItemsPublished(from, node, items)
            where node == XMPPNamespaces.avatarMetadata:
            await handleAvatarMetadataPublished(from: from, items: items, accountID: accountID)
        case let .vcardAvatarHashReceived(from, hash):
            await handleVCardAvatarHash(from: from, hash: hash, accountID: accountID)
        case .disconnected:
            serverSupportsConversion = false
            ownAvatarHash = nil
        case .streamResumed, .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged, .roomSubjectChanged,
             .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived, .roomDestroyed,
             .mucSelfPingFailed,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .jingleFileRequestReceived, .jingleChecksumReceived, .jingleChecksumMismatch,
             .jingleContentAddReceived, .jingleContentAccepted,
             .jingleContentRejected, .jingleContentRemoved,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced,
             .oobIQOfferReceived, .serviceOutageReceived:
            break
        }
    }

    // MARK: - Public API

    /// Publishes the user's avatar via XEP-0084 PEP and optionally XEP-0153 vCard.
    public func publishAvatar(imageData: Data, mimeType: String, accountID: UUID) async throws {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let pepModule = await client.module(ofType: PEPModule.self) else { return }
        guard let presenceModule = await client.module(ofType: PresenceModule.self) else { return }

        let hash = sha1Hex(Array(imageData))
        let base64String = imageData.base64EncodedString()

        // Publish avatar data
        var dataPayload = DuckoXMPP.XMLElement(name: "data", namespace: XMPPNamespaces.avatarData)
        dataPayload.addText(base64String)
        try await pepModule.publishItem(
            node: XMPPNamespaces.avatarData,
            itemID: hash,
            payload: dataPayload
        )

        // Publish avatar metadata
        let metadata = buildMetadataElement(hash: hash, mimeType: mimeType, bytes: imageData.count)
        try await pepModule.publishItem(
            node: XMPPNamespaces.avatarMetadata,
            itemID: hash,
            payload: metadata
        )

        // Update vCard photo if server doesn't do conversion
        if !serverSupportsConversion {
            await updateVCardPhoto(bytes: Array(imageData), mimeType: mimeType, accountID: accountID)
        }

        ownAvatarHash = hash
        presenceModule.setOwnAvatarHash(hash)
        try? await presenceModule.broadcastPresence(show: presenceService?.currentShow, status: presenceService?.myStatusMessage)
        await resendPresenceToMUCRooms(client: client, presenceModule: presenceModule)
    }

    /// Removes the user's avatar.
    public func removeAvatar(accountID: UUID) async throws {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let pepModule = await client.module(ofType: PEPModule.self) else { return }
        guard let presenceModule = await client.module(ofType: PresenceModule.self) else { return }

        // Publish empty metadata
        let metadata = DuckoXMPP.XMLElement(name: "metadata", namespace: XMPPNamespaces.avatarMetadata)
        try await pepModule.publishItem(
            node: XMPPNamespaces.avatarMetadata,
            itemID: "current",
            payload: metadata
        )

        if !serverSupportsConversion {
            await clearVCardPhoto(accountID: accountID)
        }

        ownAvatarHash = nil
        presenceModule.setOwnAvatarHash(nil)
        try? await presenceModule.broadcastPresence(show: presenceService?.currentShow, status: presenceService?.myStatusMessage)
        await resendPresenceToMUCRooms(client: client, presenceModule: presenceModule)
    }

    /// Fetches a contact's avatar. Returns `AvatarData` or nil.
    public func fetchAvatar(for jid: BareJID, accountID: UUID) async -> AvatarData? {
        // Try PEP first
        if let result = await fetchPEPAvatar(for: jid, accountID: accountID) {
            return result
        }
        // Fall back to vCard
        return await fetchVCardAvatar(for: jid, accountID: accountID)
    }

    // MARK: - Private: MUC Presence

    /// XEP-0398 §4: Re-send directed presence to joined MUC rooms
    /// so room occupants receive the updated vcard-temp:x:update hash.
    private func resendPresenceToMUCRooms(client: XMPPClient, presenceModule: PresenceModule) async {
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        let show = presenceService?.currentShow
        let status = presenceService?.myStatusMessage
        for roomJID in mucModule.joinedRoomFullJIDs {
            try? await presenceModule.sendDirectedPresence(to: roomJID, show: show, status: status)
        }
    }

    // MARK: - Private: Connect

    private func handleConnected(accountID: UUID) async {
        async let conversionResult: Void = detectConversionSupport(accountID: accountID)
        async let hashResult: Void = loadOwnAvatarHash(accountID: accountID)
        _ = await (try? conversionResult, try? hashResult)
    }

    private func detectConversionSupport(accountID: UUID) async {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let discoModule = await client.module(ofType: ServiceDiscoveryModule.self) else { return }
        guard let account = accountService?.accounts.first(where: { $0.id == accountID }) else { return }

        do {
            let info = try await discoModule.queryInfo(for: .bare(account.jid))
            serverSupportsConversion = info.features.contains(XMPPNamespaces.pepVCardConversion)
            if serverSupportsConversion {
                log.info("Server supports XEP-0398 PEP-vCard conversion")
            }
        } catch {
            log.warning("Failed to query server features: \(error.localizedDescription)")
        }
    }

    private func loadOwnAvatarHash(accountID: UUID) async {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let vcardModule = await client.module(ofType: VCardModule.self) else { return }
        guard let presenceModule = await client.module(ofType: PresenceModule.self) else { return }

        do {
            let vcard = try await vcardModule.fetchOwnVCard(forceRefresh: true)
            ownAvatarHash = vcard?.photoHash
            presenceModule.setOwnAvatarHash(ownAvatarHash)
            // Re-broadcast presence so contacts receive the XEP-0153 hash
            // (initial presence was sent before this fetch completed)
            try? await presenceModule.broadcastPresence(show: presenceService?.currentShow, status: presenceService?.myStatusMessage)
        } catch {
            log.warning("Failed to fetch own vCard for avatar hash: \(error.localizedDescription)")
        }
    }

    // MARK: - Private: PEP Avatar Metadata

    private func handleAvatarMetadataPublished(from: BareJID, items: [PEPItem], accountID: UUID) async {
        // Only process contacts' avatars, not our own
        guard let account = accountService?.accounts.first(where: { $0.id == accountID }),
              from != account.jid else { return }

        guard let item = items.first else { return }
        let metadata = item.payload

        // Empty metadata = avatar disabled
        guard let info = metadata.child(named: "info") else {
            await clearContactAvatar(jid: from, accountID: accountID)
            return
        }

        let hash = info.attribute("id")
        guard let contact = await findContact(jid: from, accountID: accountID) else { return }

        // Skip if hash matches
        if let hash, contact.avatarHash == hash { return }

        // Fetch avatar data from PEP
        await fetchAndStoreAvatar(for: contact, hash: hash, accountID: accountID)
    }

    // MARK: - Private: vCard Avatar Hash

    private func handleVCardAvatarHash(from: BareJID, hash: String?, accountID: UUID) async {
        guard let contact = await findContact(jid: from, accountID: accountID) else { return }

        // No avatar
        guard let hash else {
            if contact.avatarHash != nil {
                await clearContactAvatar(jid: from, accountID: accountID)
            }
            return
        }

        // Skip if hash matches
        if contact.avatarHash == hash { return }

        // Fetch vCard to get photo
        guard let client = accountService?.client(for: accountID) else { return }
        guard let vcardModule = await client.module(ofType: VCardModule.self) else { return }

        do {
            let vcard = try await vcardModule.fetchVCard(for: from, forceRefresh: true)
            guard let photoData = vcard?.photoData else { return }

            var updated = contact
            updated.avatarData = Data(photoData)
            updated.avatarHash = hash
            try? await store.upsertContact(updated)
            try? await rosterService?.loadContacts(for: accountID)
        } catch {
            log.warning("Failed to fetch vCard avatar for \(from): \(error.localizedDescription)")
        }
    }

    // MARK: - Private: Fetch Helpers

    private func fetchAndStoreAvatar(for contact: Contact, hash: String?, accountID: UUID) async {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let pepModule = await client.module(ofType: PEPModule.self) else { return }

        do {
            let items = try await pepModule.retrieveItems(
                node: XMPPNamespaces.avatarData,
                from: contact.jid,
                maxItems: 1
            )
            guard let item = items.first,
                  let base64Text = item.payload.textContent,
                  let data = Data(base64Encoded: base64Text, options: .ignoreUnknownCharacters)
            else { return }

            var updated = contact
            updated.avatarData = data
            updated.avatarHash = hash ?? sha1Hex(Array(data))
            try? await store.upsertContact(updated)
            try? await rosterService?.loadContacts(for: accountID)
        } catch {
            log.warning("Failed to fetch PEP avatar data for \(contact.jid): \(error.localizedDescription)")
        }
    }

    private func fetchPEPAvatar(for jid: BareJID, accountID: UUID) async -> AvatarData? {
        guard let client = accountService?.client(for: accountID) else { return nil }
        guard let pepModule = await client.module(ofType: PEPModule.self) else { return nil }

        do {
            // Fetch metadata first
            let metaItems = try await pepModule.retrieveItems(
                node: XMPPNamespaces.avatarMetadata,
                from: jid,
                maxItems: 1
            )
            guard let metaItem = metaItems.first,
                  let info = metaItem.payload.child(named: "info") else { return nil }

            let hash = info.attribute("id") ?? ""
            let mimeType = info.attribute("type") ?? "image/png"

            // Fetch data
            let dataItems = try await pepModule.retrieveItems(
                node: XMPPNamespaces.avatarData,
                from: jid,
                maxItems: 1
            )
            guard let dataItem = dataItems.first,
                  let base64Text = dataItem.payload.textContent,
                  let data = Data(base64Encoded: base64Text, options: .ignoreUnknownCharacters)
            else { return nil }

            return AvatarData(data: data, hash: hash, mimeType: mimeType)
        } catch {
            return nil
        }
    }

    private func fetchVCardAvatar(for jid: BareJID, accountID: UUID) async -> AvatarData? {
        guard let client = accountService?.client(for: accountID) else { return nil }
        guard let vcardModule = await client.module(ofType: VCardModule.self) else { return nil }

        do {
            let vcard = try await vcardModule.fetchVCard(for: jid, forceRefresh: true)
            guard let photoData = vcard?.photoData else { return nil }
            let hash = vcard?.photoHash ?? sha1Hex(photoData)
            let mimeType = vcard?.photoType ?? "image/png"
            return AvatarData(data: Data(photoData), hash: hash, mimeType: mimeType)
        } catch {
            return nil
        }
    }

    // MARK: - Private: Update Helpers

    private func clearContactAvatar(jid: BareJID, accountID: UUID) async {
        guard var contact = await findContact(jid: jid, accountID: accountID) else { return }
        contact.avatarData = nil
        contact.avatarHash = nil
        try? await store.upsertContact(contact)
        try? await rosterService?.loadContacts(for: accountID)
    }

    private func updateVCardPhoto(bytes: [UInt8], mimeType: String, accountID: UUID) async {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let vcardModule = await client.module(ofType: VCardModule.self) else { return }

        do {
            var vcard = try await vcardModule.fetchOwnVCard(forceRefresh: true) ?? VCardModule.VCard()
            vcard.photoData = bytes
            vcard.photoType = mimeType
            vcard.photoHash = sha1Hex(bytes)
            try await vcardModule.publishVCard(vcard)
        } catch {
            log.warning("Failed to update vCard photo: \(error.localizedDescription)")
        }
    }

    private func clearVCardPhoto(accountID: UUID) async {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let vcardModule = await client.module(ofType: VCardModule.self) else { return }

        do {
            var vcard = try await vcardModule.fetchOwnVCard(forceRefresh: true) ?? VCardModule.VCard()
            vcard.photoData = nil
            vcard.photoType = nil
            vcard.photoHash = nil
            try await vcardModule.publishVCard(vcard)
        } catch {
            log.warning("Failed to clear vCard photo: \(error.localizedDescription)")
        }
    }

    // MARK: - Private: Metadata XML

    private func buildMetadataElement(hash: String, mimeType: String, bytes: Int) -> DuckoXMPP.XMLElement {
        var metadata = DuckoXMPP.XMLElement(name: "metadata", namespace: XMPPNamespaces.avatarMetadata)
        let info = DuckoXMPP.XMLElement(name: "info", attributes: [
            "id": hash,
            "type": mimeType,
            "bytes": "\(bytes)"
        ])
        metadata.addChild(info)
        return metadata
    }

    // MARK: - Private: Contact Lookup

    private func findContact(jid: BareJID, accountID: UUID) async -> Contact? {
        let contacts = await (try? store.fetchContacts(for: accountID)) ?? []
        return contacts.first(where: { $0.jid == jid })
    }
}
