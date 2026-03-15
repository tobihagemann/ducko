import DuckoXMPP
import Foundation
import os

private let log = Logger(subsystem: "com.ducko.core", category: "omemo")

@MainActor @Observable
public final class OMEMOService {
    private let omemoStore: any OMEMOStore
    private weak var accountService: AccountService?
    private weak var chatService: ChatService?

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

    // MARK: - Module Building

    /// Creates a pre-configured OMEMOModule with persisted identity and sessions.
    func buildModule(for accountJID: BareJID, pepModule: PEPModule) async -> OMEMOModule {
        let module = OMEMOModule(pepModule: pepModule)
        let jidString = accountJID.description

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
        case let .omemoEncryptedMessageReceived(from, decryptedBody, _):
            await handleEncryptedMessageReceived(from: from, decryptedBody: decryptedBody, accountID: accountID)
        case let .omemoSessionEstablished(jid, deviceID):
            await handleSessionEstablished(jid: jid, deviceID: deviceID, accountID: accountID)
        case .connected:
            await handleConnected(accountID: accountID)
        case .disconnected:
            break
        case .streamResumed, .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged, .roomSubjectChanged,
             .roomInviteReceived, .roomMessageReceived,
             .roomDestroyed, .mucSelfPingFailed,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .blockListLoaded, .contactBlocked, .contactUnblocked:
            break
        }
    }

    // MARK: - Encryption

    /// Returns `true` if the peer has at least one trusted OMEMO device.
    func shouldEncrypt(jid: BareJID, accountID: UUID) async -> Bool {
        guard let accountJID = accountJIDString(for: accountID) else { return false }
        let devices = await (try? omemoStore.loadAllTrustedDevices(for: jid.description, accountJID: accountJID)) ?? []
        return devices.contains { $0.trustLevel.isTrustedForEncryption }
    }

    /// Encrypts a message body and returns the OMEMO stanza elements.
    func encryptMessage(
        body: String,
        to jid: BareJID,
        accountID: UUID
    ) async throws -> OMEMOModule.EncryptedMessageElements {
        guard let client = accountService?.client(for: accountID) else {
            throw OMEMOServiceError.notConnected
        }
        guard let omemoModule = await client.module(ofType: OMEMOModule.self) else {
            throw OMEMOServiceError.omemoNotAvailable
        }

        // Filter by trusted devices
        let deviceIDs = await trustedDeviceIDs(for: jid, accountID: accountID)
        let elements = try await omemoModule.encryptMessage(
            plaintext: body, to: jid, recipientDeviceIDs: deviceIDs.isEmpty ? nil : deviceIDs
        )

        // Persist updated sessions
        await saveModuleSessions(module: omemoModule, accountID: accountID)

        return elements
    }

    private func trustedDeviceIDs(for jid: BareJID, accountID: UUID) async -> [UInt32] {
        guard let accountJID = accountJIDString(for: accountID) else { return [] }
        let allDevices = await (try? omemoStore.loadAllTrustedDevices(for: jid.description, accountJID: accountJID)) ?? []
        return allDevices.filter(\.trustLevel.isTrustedForEncryption).map(\.deviceID)
    }

    // MARK: - Trust Management

    // periphery:ignore - specced feature, wired in Prompt 20
    public func trustDevice(accountID: UUID, peerJID: String, deviceID: UInt32, fingerprint: String) async throws {
        try await setTrustLevel(.trusted, accountID: accountID, peerJID: peerJID, deviceID: deviceID, fingerprint: fingerprint)
    }

    // periphery:ignore - specced feature, wired in Prompt 20
    public func untrustDevice(accountID: UUID, peerJID: String, deviceID: UInt32) async throws {
        guard let accountJID = accountJIDString(for: accountID) else { return }
        guard let existing = try await omemoStore.loadTrust(accountJID: accountJID, peerJID: peerJID, deviceID: deviceID) else { return }
        try await setTrustLevel(.untrusted, accountID: accountID, peerJID: peerJID, deviceID: deviceID, fingerprint: existing.fingerprint)
    }

    // periphery:ignore - specced feature, wired in Prompt 20
    public func verifyDevice(accountID: UUID, peerJID: String, deviceID: UInt32, fingerprint: String) async throws {
        try await setTrustLevel(.verified, accountID: accountID, peerJID: peerJID, deviceID: deviceID, fingerprint: fingerprint)
    }

    // periphery:ignore - specced feature, wired in Prompt 20
    public func trustedDevices(for peerJID: String, accountID: UUID) async throws -> [OMEMOTrust] {
        guard let accountJID = accountJIDString(for: accountID) else { return [] }
        return try await omemoStore.loadAllTrustedDevices(for: peerJID, accountJID: accountJID)
    }

    // periphery:ignore - specced feature, wired in Prompt 20
    public func ownFingerprint(accountID: UUID) async throws -> String? {
        guard let accountJID = accountJIDString(for: accountID) else { return nil }
        guard let identity = try await omemoStore.loadIdentity(for: accountJID) else { return nil }
        return identity.identityKeyData.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Private Event Handlers

    private func handleDeviceListReceived(jid: BareJID, devices: [UInt32], accountID: UUID) async {
        guard let accountJID = accountJIDString(for: accountID) else { return }
        let existing = await (try? omemoStore.loadAllTrustedDevices(for: jid.description, accountJID: accountJID)) ?? []
        let knownDeviceIDs = Set(existing.map(\.deviceID))
        for deviceID in devices where !knownDeviceIDs.contains(deviceID) {
            let trust = OMEMOTrust(
                accountJID: accountJID, peerJID: jid.description,
                deviceID: deviceID, fingerprint: "", trustLevel: .undecided
            )
            try? await omemoStore.saveTrust(trust)
        }
    }

    private func handleEncryptedMessageReceived(from: JID, decryptedBody: String?, accountID: UUID) async {
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
            fromJID: peerJID.description,
            body: body,
            timestamp: Date(),
            isOutgoing: isOutgoing,
            isRead: isOutgoing,
            isDelivered: false,
            isEdited: false,
            type: "chat",
            isEncrypted: true
        )

        await chatService.persistEncryptedMessage(message, in: conversation, accountID: accountID)

        // Persist session state after decryption (ratchet may have advanced)
        if let client = accountService?.client(for: accountID),
           let omemoModule = await client.module(ofType: OMEMOModule.self) {
            await saveModuleSessions(module: omemoModule, accountID: accountID)
        }
    }

    private func handleSessionEstablished(jid: BareJID, deviceID: UInt32, accountID: UUID) async {
        guard let client = accountService?.client(for: accountID),
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
    }

    private func handleConnected(accountID: UUID) async {
        guard let client = accountService?.client(for: accountID),
              let omemoModule = await client.module(ofType: OMEMOModule.self)
        else { return }
        guard let accountJID = accountJIDString(for: accountID) else { return }

        // Persist identity if this is a first-time generation
        let existingIdentity = try? await omemoStore.loadIdentity(for: accountJID)
        if existingIdentity == nil, let identityData = omemoModule.ownIdentityData {
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
        }

        // Mark consumed pre-keys
        let consumed = omemoModule.consumedPreKeyIDs()
        for keyID in consumed {
            try? await omemoStore.consumePreKey(id: keyID, accountJID: accountJID)
        }

        // Check if pre-key replenishment is needed
        await replenishPreKeysIfNeeded(accountJID: accountJID, module: omemoModule)
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

    // periphery:ignore - called by trust management API
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

// MARK: - Errors

enum OMEMOServiceError: Error {
    case notConnected
    case omemoNotAvailable
}
