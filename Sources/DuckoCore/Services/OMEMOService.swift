import CryptoKit
import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.omemo")

private func omemoFingerprint(from identityKey: some Sequence<UInt8>) -> String {
    identityKey.map { String(format: "%02x", $0) }.joined()
}

@MainActor @Observable
public final class OMEMOService {
    private let omemoStore: any OMEMOStore
    private weak var accountService: AccountService?
    private weak var chatService: ChatService?
    /// Per-account previously-seen-device-IDs set surfaced to `OMEMOModule`
    /// via `PreviouslySeenDeviceIDsProviding`. Lives on the service so it
    /// outlives module reconnects (each reconnect builds a fresh module);
    /// without that, the prior-observation gate in `pruneStaleBundles` would
    /// always find an empty set and never auto-retract. Keyed by
    /// `UUID.uuidString` because the protocol takes opaque `String`.
    private var previouslySeenDeviceIDsByAccount: [String: Set<UInt32>] = [:]

    public init(omemoStore: any OMEMOStore) {
        self.omemoStore = omemoStore
    }

    // MARK: - Wiring

    func setAccountService(_ service: AccountService) {
        accountService = service
    }

    func setChatService(_ service: ChatService) {
        chatService = service
    }

    /// Drops the previously-seen-device-IDs entry for `accountID` so it does
    /// not survive into a future re-creation of the account. Called by
    /// `AccountService.deleteAccount` to keep the in-memory map bounded.
    func purgePreviouslySeenDeviceIDs(accountID: UUID) {
        previouslySeenDeviceIDsByAccount.removeValue(forKey: accountID.uuidString)
    }

    // MARK: - Module Building

    /// Creates a pre-configured OMEMOModule with persisted identity and sessions.
    func buildModule(for accountJID: BareJID, accountID: UUID, pepModule: PEPModule) async -> OMEMOModule {
        let module = OMEMOModule(pepModule: pepModule)
        let jidString = accountJID.description

        wireIdentityKeyValidator(on: module, accountJID: jidString)
        // `pruneStaleBundles` uses this to gate auto-retract on a prior
        // observation. The set lives on the service so it survives reconnects
        // (modules are rebuilt per reconnect; the service is held by
        // `AppEnvironment` and outlives them).
        module.configurePreviouslySeenDeviceIDsProvider(self, accountID: accountID.uuidString)

        // Restore persisted identity
        if let stored = try? await omemoStore.loadIdentity(for: jidString) {
            let preKeys = await (try? omemoStore.loadPreKeys(for: jidString)) ?? []
            let signedPreKey = try? await omemoStore.loadSignedPreKey(for: jidString)

            let preKeyData = preKeys.filter { !$0.isUsed }.map {
                OMEMOModule.OMEMOIdentityData.PreKeyData(
                    keyID: $0.keyID, keyRaw: Array($0.keyData)
                )
            }

            if let spk = signedPreKey {
                let identityData = OMEMOModule.OMEMOIdentityData(
                    deviceID: stored.deviceID,
                    identityKeyRaw: Array(stored.identityKeyData),
                    signedPreKeyID: spk.keyID,
                    signedPreKeyRaw: Array(spk.keyData),
                    signedPreKeySignature: Array(spk.signature),
                    preKeys: preKeyData
                )
                module.configureIdentity(identityData)
            }
        }

        // Restore persisted sessions
        if let sessions = try? await omemoStore.loadSessions(for: jidString) {
            let entries = sessions.map {
                OMEMOModule.StoredSessionEntry(
                    jid: BareJID.parse($0.peerJID) ?? accountJID,
                    deviceID: $0.peerDeviceID,
                    sessionData: Array($0.sessionData),
                    associatedData: Array($0.associatedData)
                )
            }
            module.restoreSessions(entries)
        }

        return module
    }

    // MARK: - Event Handling

    func handleEvent(_ event: XMPPEvent, accountID: UUID) async {
        switch event {
        case let .omemoDeviceListReceived(jid, devices):
            await handleDeviceListReceived(jid: jid, devices: devices, accountID: accountID)
        case let .omemoEncryptedMessageReceived(from, decryptedBody, _, stanzaID):
            await handleEncryptedMessageReceived(from: from, decryptedBody: decryptedBody, stanzaID: stanzaID, accountID: accountID)
        case let .omemoSessionEstablished(jid, deviceID, identityKey):
            await handleSessionEstablished(
                jid: jid, deviceID: deviceID,
                identityKey: identityKey, accountID: accountID
            )
        case .omemoSessionAdvanced:
            if let client = accountService?.connectedClient(for: accountID),
               let omemoModule = await client.module(ofType: OMEMOModule.self) {
                await saveModuleSessions(module: omemoModule, accountID: accountID)
            }
        case .connected:
            await handleConnected(accountID: accountID)
        case .disconnected:
            break
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
             .vcardAvatarHashReceived,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged, .roomSubjectChanged,
             .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived,
             .roomDestroyed, .mucSelfPingFailed,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .jingleFileRequestReceived, .jingleChecksumReceived, .jingleChecksumMismatch,
             .jingleContentAddReceived, .jingleContentAccepted,
             .jingleContentRejected, .jingleContentRemoved,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoRecipientsPartial,
             .oobIQOfferReceived, .serviceOutageReceived:
            break
        }
    }

    // MARK: - Encryption

    /// Returns trusted device IDs if encryption should proceed, or `nil` if not.
    func shouldEncrypt(jid: BareJID, accountID: UUID, conversationEncryptionEnabled: Bool) async -> [UInt32]? {
        guard conversationEncryptionEnabled else { return nil }
        let deviceIDs = await trustedDeviceIDs(for: jid, accountID: accountID)
        return deviceIDs.isEmpty ? nil : deviceIDs
    }

    /// Encrypts a message body and returns the OMEMO stanza elements.
    func encryptMessage(
        body: String,
        to jid: BareJID,
        trustedDeviceIDs: [UInt32],
        accountID: UUID
    ) async throws -> OMEMOModule.EncryptedMessageElements {
        guard !trustedDeviceIDs.isEmpty else {
            throw OMEMOServiceError.noTrustedRecipients
        }
        guard let client = accountService?.connectedClient(for: accountID) else {
            throw OMEMOServiceError.notConnected(accountID)
        }
        guard let omemoModule = await client.module(ofType: OMEMOModule.self) else {
            throw OMEMOServiceError.omemoNotAvailable
        }

        let ownDeviceIDs = await trustedOwnDeviceIDs(accountID: accountID)
        let elements = try await omemoModule.encryptMessage(
            plaintext: body, to: jid,
            recipientDeviceIDs: trustedDeviceIDs, ownDeviceIDs: ownDeviceIDs
        )

        // Persist updated sessions
        await saveModuleSessions(module: omemoModule, accountID: accountID)

        return elements
    }

    private func trustedDeviceIDs(for jid: BareJID, accountID: UUID) async -> [UInt32] {
        guard let accountJID = accountJIDString(for: accountID) else { return [] }
        let allDevices = await (try? omemoStore.loadAllDevices(for: jid.description, accountJID: accountJID)) ?? []
        let tofu = OMEMOPreferences.shared.trustOnFirstUse
        return allDevices.filter { $0.trustLevel.isTrustedForEncryption(trustOnFirstUse: tofu) }.map(\.deviceID)
    }

    private func trustedOwnDeviceIDs(accountID: UUID) async -> [UInt32] {
        guard let ownJID = accountService?.accounts.first(where: { $0.id == accountID })?.jid else { return [] }
        guard let accountJID = accountJIDString(for: accountID) else { return [] }
        // Own devices always use TOFU semantics — refusing to encrypt to your
        // own undecided devices breaks multi-device message sync.
        let allDevices = await (try? omemoStore.loadAllDevices(for: ownJID.description, accountJID: accountJID)) ?? []
        return allDevices.filter { $0.trustLevel.isTrustedForEncryption(trustOnFirstUse: true) }.map(\.deviceID)
    }

    // MARK: - Trust Management

    public func trustDevice(accountID: UUID, peerJID: String, deviceID: UInt32, fingerprint: String) async throws {
        try await setTrustLevel(.trusted, accountID: accountID, peerJID: peerJID, deviceID: deviceID, fingerprint: fingerprint)
    }

    public func untrustDevice(accountID: UUID, peerJID: String, deviceID: UInt32) async throws {
        guard let accountJID = accountJIDString(for: accountID) else { return }
        guard let existing = try await omemoStore.loadTrust(accountJID: accountJID, peerJID: peerJID, deviceID: deviceID) else { return }
        try await setTrustLevel(.untrusted, accountID: accountID, peerJID: peerJID, deviceID: deviceID, fingerprint: existing.fingerprint)
    }

    public func verifyDevice(accountID: UUID, peerJID: String, deviceID: UInt32, fingerprint: String) async throws {
        try await setTrustLevel(.verified, accountID: accountID, peerJID: peerJID, deviceID: deviceID, fingerprint: fingerprint)
    }

    public func ownFingerprint(accountID: UUID) async -> String? {
        await ownDeviceInfo(accountID: accountID)?.fingerprint
    }

    /// Returns device info for all known devices of a peer, suitable for UI display.
    public func deviceInfoList(for peerJID: String, accountID: UUID) async -> [OMEMODeviceInfo] {
        guard let accountJID = accountJIDString(for: accountID) else { return [] }
        let devices = await (try? omemoStore.loadAllDevices(for: peerJID, accountJID: accountJID)) ?? []
        return devices.map {
            OMEMODeviceInfo(
                peerJID: $0.peerJID, deviceID: $0.deviceID,
                fingerprint: $0.fingerprint, trustLevel: $0.trustLevel
            )
        }
    }

    /// Returns own device info (device ID + fingerprint) for side-by-side verification.
    public func ownDeviceInfo(accountID: UUID) async -> OMEMODeviceInfo? {
        guard let accountJID = accountJIDString(for: accountID) else { return nil }
        guard let identity = try? await omemoStore.loadIdentity(for: accountJID) else { return nil }
        guard let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: identity.identityKeyData) else {
            return nil
        }
        let fingerprint = omemoFingerprint(from: privateKey.publicKey.rawRepresentation)
        return OMEMODeviceInfo(
            peerJID: accountJID, deviceID: identity.deviceID,
            fingerprint: fingerprint, trustLevel: .verified
        )
    }

    // MARK: - Group Chat Encryption

    /// Encrypts a message for all members of a group chat room.
    func encryptGroupMessage(
        body: String,
        roomJID: BareJID,
        memberJIDs: [BareJID],
        accountID: UUID
    ) async throws -> OMEMOModule.EncryptedMessageElements {
        guard let client = accountService?.connectedClient(for: accountID) else {
            throw OMEMOServiceError.notConnected(accountID)
        }
        guard let omemoModule = await client.module(ofType: OMEMOModule.self) else {
            throw OMEMOServiceError.omemoNotAvailable
        }

        let recipients = await buildGroupRecipients(memberJIDs: memberJIDs, accountID: accountID)
        guard !recipients.isEmpty else {
            throw OMEMOServiceError.noTrustedRecipients
        }

        let ownDeviceIDs = await trustedOwnDeviceIDs(accountID: accountID)
        let elements = try await omemoModule.encryptGroupMessage(
            plaintext: body, roomJID: roomJID,
            recipients: recipients, ownDeviceIDs: ownDeviceIDs
        )
        await saveModuleSessions(module: omemoModule, accountID: accountID)
        return elements
    }

    private func buildGroupRecipients(
        memberJIDs: [BareJID],
        accountID: UUID
    ) async -> [(jid: BareJID, deviceIDs: [UInt32])] {
        // Exclude own JID — encryptGroupMessage encrypts for own devices separately
        let ownJID = accountService?.accounts.first(where: { $0.id == accountID })?.jid
        let filtered = memberJIDs.filter { $0 != ownJID }
        return await withTaskGroup(of: (BareJID, [UInt32]).self) { group in
            for jid in filtered {
                group.addTask {
                    let deviceIDs = await self.trustedDeviceIDs(for: jid, accountID: accountID)
                    return (jid, deviceIDs)
                }
            }
            var recipients: [(jid: BareJID, deviceIDs: [UInt32])] = []
            for await (jid, deviceIDs) in group where !deviceIDs.isEmpty {
                recipients.append((jid: jid, deviceIDs: deviceIDs))
            }
            return recipients
        }
    }

    // MARK: - Private Event Handlers

    private func handleDeviceListReceived(jid: BareJID, devices: [UInt32], accountID: UUID) async {
        guard let accountJID = accountJIDString(for: accountID) else { return }
        let existing = await (try? omemoStore.loadAllDevices(for: jid.description, accountJID: accountJID)) ?? []
        let knownDeviceIDs = Set(existing.map(\.deviceID))
        for deviceID in devices where !knownDeviceIDs.contains(deviceID) {
            let trust = OMEMOTrust(
                accountJID: accountJID, peerJID: jid.description,
                deviceID: deviceID, fingerprint: "", trustLevel: .undecided
            )
            try? await omemoStore.saveTrust(trust)
        }
    }

    private func handleEncryptedMessageReceived(from: JID, decryptedBody: String?, stanzaID: String?, accountID: UUID) async {
        let senderJID = from.bareJID
        guard let chatService else { return }

        // Determine if this is our own message echoed back (carbon/MAM)
        let ownJID = accountService?.accounts.first(where: { $0.id == accountID })?.jid
        let isOutgoing = ownJID != nil && senderJID == ownJID
        let peerJID = isOutgoing ? (from.bareJID) : senderJID

        let conversation: Conversation
        do {
            conversation = try await chatService.openConversation(for: peerJID, accountID: accountID)
        } catch {
            log.warning("Failed to open conversation for OMEMO message from \(senderJID): \(error)")
            return
        }

        let body = decryptedBody ?? "Could not decrypt this message"
        let message = ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            serverID: stanzaID,
            fromJID: peerJID.description,
            body: body,
            timestamp: Date(),
            isOutgoing: isOutgoing,
            isDelivered: false,
            isEdited: false,
            type: "chat",
            isEncrypted: true
        )

        await chatService.persistEncryptedMessage(message, in: conversation, accountID: accountID)

        // Persist session state after decryption (ratchet may have advanced)
        if let client = accountService?.connectedClient(for: accountID),
           let omemoModule = await client.module(ofType: OMEMOModule.self) {
            await saveModuleSessions(module: omemoModule, accountID: accountID)
        }
    }

    private func handleSessionEstablished(
        jid: BareJID, deviceID: UInt32,
        identityKey: [UInt8], accountID: UUID
    ) async {
        guard let client = accountService?.connectedClient(for: accountID),
              let omemoModule = await client.module(ofType: OMEMOModule.self)
        else { return }

        guard let entry = omemoModule.exportSession(jid: jid, deviceID: deviceID) else { return }
        guard let accountJID = accountJIDString(for: accountID) else { return }

        let session = OMEMOStoredSession(
            accountJID: accountJID, peerJID: jid.description,
            peerDeviceID: deviceID,
            sessionData: Data(entry.sessionData),
            associatedData: Data(entry.associatedData)
        )
        try? await omemoStore.saveSession(session)

        // Store fingerprint from identity key
        let fingerprint = omemoFingerprint(from: identityKey)
        let existing = try? await omemoStore.loadTrust(
            accountJID: accountJID, peerJID: jid.description, deviceID: deviceID
        )
        if let existing, existing.fingerprint.isEmpty {
            // Fill placeholder fingerprint
            let updated = OMEMOTrust(
                accountJID: accountJID, peerJID: jid.description,
                deviceID: deviceID, fingerprint: fingerprint,
                trustLevel: existing.trustLevel
            )
            try? await omemoStore.saveTrust(updated)
        } else if let existing, !existing.fingerprint.isEmpty, existing.fingerprint != fingerprint {
            log.warning("Identity key changed for \(jid) device \(deviceID)")
        } else if existing == nil {
            // New device — create undecided trust record with fingerprint
            let trust = OMEMOTrust(
                accountJID: accountJID, peerJID: jid.description,
                deviceID: deviceID, fingerprint: fingerprint,
                trustLevel: .undecided
            )
            try? await omemoStore.saveTrust(trust)
        }
    }

    private func handleConnected(accountID: UUID) async {
        guard let client = accountService?.connectedClient(for: accountID),
              let omemoModule = await client.module(ofType: OMEMOModule.self)
        else { return }
        guard let accountJID = accountJIDString(for: accountID) else { return }

        await handleConnectedFirstTimePersistence(
            provider: omemoModule,
            accountJID: accountJID
        )

        // Check if pre-key replenishment is needed
        await replenishPreKeysIfNeeded(accountJID: accountJID, module: omemoModule)
    }

    /// First-time identity persistence + consumed-pre-key sync.
    ///
    /// Split out from ``handleConnected(accountID:)`` so unit tests can drive
    /// the polling and persistence branches via a stub
    /// ``OMEMOIdentityProviding`` and a short ``pollTimeout``, bypassing the
    /// 5 s real-time wait and the 25-pre-key replenishment trigger. Production
    /// `handleConnected` calls this with the live module and then runs
    /// replenishment separately.
    package func handleConnectedFirstTimePersistence(
        provider: any OMEMOIdentityProviding,
        accountJID: String,
        pollTimeout: Duration = .seconds(5)
    ) async {
        // First-time persistence only: if an identity is already stored, the
        // module will restore it on handleConnect and there's nothing to do
        // here. Skip both the readiness poll and the persistence writes.
        let existingIdentity = try? await omemoStore.loadIdentity(for: accountJID)
        if existingIdentity == nil {
            // `.connected` is yielded before `OMEMOModule.handleConnect` runs,
            // so `ownIdentityData` may still be `nil` on first-time generation.
            // Poll up to `pollTimeout` (default ~5 s — two IQ round-trips:
            // publish device list + bundle). Capture the identity inside the
            // closure to avoid a re-read race with `handleDisconnect` nil'ing
            // `ownIdentity`.
            var captured: OMEMOModule.OMEMOIdentityData?
            _ = await pollUntil(
                {
                    if let data = provider.ownIdentityData {
                        captured = data
                        return true
                    }
                    return false
                },
                timeout: pollTimeout,
                interval: .milliseconds(50)
            )
            if let identityData = captured {
                let stored = OMEMOStoredIdentity(
                    accountJID: accountJID,
                    deviceID: identityData.deviceID,
                    identityKeyData: Data(identityData.identityKeyRaw),
                    registrationID: 0
                )
                try? await omemoStore.saveIdentity(stored)

                // Persist pre-keys
                let preKeys = identityData.preKeys.map {
                    OMEMOStoredPreKey(
                        accountJID: accountJID, keyID: $0.keyID,
                        keyData: Data($0.keyRaw), isUsed: false
                    )
                }
                try? await omemoStore.savePreKeys(preKeys)

                // Persist signed pre-key
                let spk = OMEMOStoredSignedPreKey(
                    accountJID: accountJID,
                    keyID: identityData.signedPreKeyID,
                    keyData: Data(identityData.signedPreKeyRaw),
                    signature: Data(identityData.signedPreKeySignature),
                    timestamp: Date()
                )
                try? await omemoStore.saveSignedPreKey(spk)
            } else {
                log.warning("OMEMO identity not ready after \(pollTimeout) wait; skipping first-time persistence")
            }
        }

        // Mark consumed pre-keys
        let consumed = provider.consumedPreKeyIDs()
        for keyID in consumed {
            try? await omemoStore.consumePreKey(id: keyID, accountJID: accountJID)
        }
    }

    // MARK: - Private Helpers

    private func saveModuleSessions(module: OMEMOModule, accountID: UUID) async {
        guard let accountJID = accountJIDString(for: accountID) else { return }
        let entries = module.allSessionEntries()
        for entry in entries {
            let session = OMEMOStoredSession(
                accountJID: accountJID, peerJID: entry.jid.description,
                peerDeviceID: entry.deviceID,
                sessionData: Data(entry.sessionData),
                associatedData: Data(entry.associatedData)
            )
            try? await omemoStore.saveSession(session)
        }
    }

    private func wireIdentityKeyValidator(on module: OMEMOModule, accountJID: String) {
        let store = omemoStore
        module.setIdentityKeyValidator { peerJID, deviceID, identityKey in
            let existing = try await store.loadTrust(
                accountJID: accountJID, peerJID: peerJID.description,
                deviceID: deviceID
            )
            if let existing {
                if existing.trustLevel == .untrusted {
                    throw OMEMOServiceError.identityKeyUntrusted
                }
                if !existing.fingerprint.isEmpty {
                    let fingerprint = omemoFingerprint(from: identityKey)
                    if existing.fingerprint != fingerprint {
                        throw OMEMOServiceError.identityKeyMismatch
                    }
                }
            }
            // No trust record or empty fingerprint — allow (TOFU);
            // fingerprint stored on session-established event
        }
    }

    private func replenishPreKeysIfNeeded(accountJID: String, module: OMEMOModule) async {
        let preKeys = await (try? omemoStore.loadPreKeys(for: accountJID)) ?? []
        let available = preKeys.filter { !$0.isUsed }
        guard available.count < OMEMOPreKeyManager.minimumPreKeyCount else { return }

        guard let identityData = module.ownIdentityData else { return }
        let maxExistingID = preKeys.map(\.keyID).max() ?? 0
        let startID = maxExistingID + 1
        let count = OMEMOPreKeyManager.targetPreKeyCount - available.count

        let newPreKeys = OMEMOPreKeyManager.generatePreKeys(startID: startID, count: count)
        let storedPreKeys = newPreKeys.map {
            OMEMOStoredPreKey(
                accountJID: accountJID, keyID: $0.keyID,
                keyData: Data($0.rawRepresentation), isUsed: false
            )
        }
        try? await omemoStore.savePreKeys(storedPreKeys)

        // Republish bundle with updated pre-keys
        let allPreKeys = await (try? omemoStore.loadPreKeys(for: accountJID))?.filter { !$0.isUsed } ?? []
        let updatedIdentity = OMEMOModule.OMEMOIdentityData(
            deviceID: identityData.deviceID,
            identityKeyRaw: identityData.identityKeyRaw,
            signedPreKeyID: identityData.signedPreKeyID,
            signedPreKeyRaw: identityData.signedPreKeyRaw,
            signedPreKeySignature: identityData.signedPreKeySignature,
            preKeys: allPreKeys.map {
                OMEMOModule.OMEMOIdentityData.PreKeyData(keyID: $0.keyID, keyRaw: Array($0.keyData))
            }
        )
        module.configureIdentity(updatedIdentity)
        log.info("Replenished pre-keys: \(count) new, \(allPreKeys.count) total available")
    }

    private func setTrustLevel(
        _ level: OMEMOTrustLevel, accountID: UUID,
        peerJID: String, deviceID: UInt32, fingerprint: String
    ) async throws {
        guard let accountJID = accountJIDString(for: accountID) else { return }
        let trust = OMEMOTrust(
            accountJID: accountJID, peerJID: peerJID,
            deviceID: deviceID, fingerprint: fingerprint, trustLevel: level
        )
        try await omemoStore.saveTrust(trust)
    }

    private func accountJIDString(for accountID: UUID) -> String? {
        accountService?.accounts.first(where: { $0.id == accountID })?.jid.description
    }
}

// MARK: - PreviouslySeenDeviceIDsProviding

extension OMEMOService: PreviouslySeenDeviceIDsProviding {
    package func previouslySeenDeviceIDs(accountID: String) async -> Set<UInt32> {
        previouslySeenDeviceIDsByAccount[accountID] ?? []
    }

    package func updatePreviouslySeenDeviceIDs(_ ids: Set<UInt32>, accountID: String) async {
        previouslySeenDeviceIDsByAccount[accountID] = ids
    }
}

// MARK: - Errors

enum OMEMOServiceError: Error, LocalizedError {
    case notConnected(UUID)
    case omemoNotAvailable
    case noTrustedRecipients
    case identityKeyMismatch
    case identityKeyUntrusted

    var errorDescription: String? {
        switch self {
        case let .notConnected(id): notConnectedDescription(id)
        case .omemoNotAvailable: "OMEMO module not available"
        case .noTrustedRecipients: "No trusted OMEMO recipients"
        case .identityKeyMismatch: "OMEMO identity key mismatch"
        case .identityKeyUntrusted: "OMEMO identity key not trusted"
        }
    }
}
