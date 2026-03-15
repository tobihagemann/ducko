import CryptoKit
import DuckoXMPP
import Foundation
import os

private let log = Logger(subsystem: "com.ducko.core", category: "omemo")

private func omemoFingerprint(from identityKey: some Sequence<UInt8>) -> String {
    identityKey.map { String(format: "%02x", $0) }.joined()
}

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

        wireIdentityKeyValidator(on: module, accountJID: jidString)

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
        case let .omemoSessionEstablished(jid, deviceID, identityKey):
            await handleSessionEstablished(
                jid: jid, deviceID: deviceID,
                identityKey: identityKey, accountID: accountID
            )
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

    /// Returns `true` if encryption is enabled for the conversation and the peer has trusted devices.
    func shouldEncrypt(jid: BareJID, accountID: UUID, conversationEncryptionEnabled: Bool) async -> Bool {
        guard conversationEncryptionEnabled else { return false }
        guard let accountJID = accountJIDString(for: accountID) else { return false }
        let devices = await (try? omemoStore.loadAllTrustedDevices(for: jid.description, accountJID: accountJID)) ?? []
        let tofu = OMEMOPreferences.shared.trustOnFirstUse
        return devices.contains { $0.trustLevel.isTrustedForEncryption(trustOnFirstUse: tofu) }
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

        // Filter recipient and own devices by trust
        let deviceIDs = await trustedDeviceIDs(for: jid, accountID: accountID)
        guard !deviceIDs.isEmpty else {
            throw OMEMOServiceError.noTrustedRecipients
        }
        let ownDeviceIDs = await trustedOwnDeviceIDs(accountID: accountID)
        let elements = try await omemoModule.encryptMessage(
            plaintext: body, to: jid,
            recipientDeviceIDs: deviceIDs, ownDeviceIDs: ownDeviceIDs
        )

        // Persist updated sessions
        await saveModuleSessions(module: omemoModule, accountID: accountID)

        return elements
    }

    private func trustedDeviceIDs(for jid: BareJID, accountID: UUID) async -> [UInt32] {
        guard let accountJID = accountJIDString(for: accountID) else { return [] }
        let allDevices = await (try? omemoStore.loadAllTrustedDevices(for: jid.description, accountJID: accountJID)) ?? []
        let tofu = OMEMOPreferences.shared.trustOnFirstUse
        return allDevices.filter { $0.trustLevel.isTrustedForEncryption(trustOnFirstUse: tofu) }.map(\.deviceID)
    }

    private func trustedOwnDeviceIDs(accountID: UUID) async -> [UInt32] {
        guard let ownJID = accountService?.accounts.first(where: { $0.id == accountID })?.jid else { return [] }
        guard let accountJID = accountJIDString(for: accountID) else { return [] }
        // Own devices always use TOFU semantics — refusing to encrypt to your
        // own undecided devices breaks multi-device message sync.
        let allDevices = await (try? omemoStore.loadAllTrustedDevices(for: ownJID.description, accountJID: accountJID)) ?? []
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

    // periphery:ignore - public API for trust inspection (used by CLI trust subcommands)
    public func trustedDevices(for peerJID: String, accountID: UUID) async throws -> [OMEMOTrust] {
        guard let accountJID = accountJIDString(for: accountID) else { return [] }
        return try await omemoStore.loadAllTrustedDevices(for: peerJID, accountJID: accountJID)
    }

    public func ownFingerprint(accountID: UUID) async -> String? {
        await ownDeviceInfo(accountID: accountID)?.fingerprint
    }

    /// Returns device info for all known devices of a peer, suitable for UI display.
    public func deviceInfoList(for peerJID: String, accountID: UUID) async -> [OMEMODeviceInfo] {
        guard let accountJID = accountJIDString(for: accountID) else { return [] }
        let devices = await (try? omemoStore.loadAllTrustedDevices(for: peerJID, accountJID: accountJID)) ?? []
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
        roomJID _: BareJID,
        memberJIDs: [BareJID],
        accountID: UUID
    ) async throws -> OMEMOModule.EncryptedMessageElements {
        guard let client = accountService?.client(for: accountID) else {
            throw OMEMOServiceError.notConnected
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
            plaintext: body, recipients: recipients, ownDeviceIDs: ownDeviceIDs
        )
        await saveModuleSessions(module: omemoModule, accountID: accountID)
        return elements
    }

    // periphery:ignore - specced feature, wired by UI when enabling group encryption
    /// Validates whether a room is suitable for OMEMO group encryption.
    public func validateRoomForOMEMO(
        memberJIDs: [BareJID],
        accountID: UUID
    ) async -> RoomOMEMOValidation {
        var membersWithoutOMEMO: [String] = []
        var encryptableMembers = 0

        for jid in memberJIDs {
            let deviceIDs = await trustedDeviceIDs(for: jid, accountID: accountID)
            if deviceIDs.isEmpty {
                membersWithoutOMEMO.append(jid.description)
            } else {
                encryptableMembers += 1
            }
        }

        return RoomOMEMOValidation(
            membersWithoutOMEMO: membersWithoutOMEMO,
            totalMembers: memberJIDs.count,
            encryptableMembers: encryptableMembers
        )
    }

    private func buildGroupRecipients(
        memberJIDs: [BareJID],
        accountID: UUID
    ) async -> [(jid: BareJID, deviceIDs: [UInt32])] {
        // Exclude own JID — encryptGroupMessage encrypts for own devices separately
        let ownJID = accountService?.accounts.first(where: { $0.id == accountID })?.jid
        var recipients: [(jid: BareJID, deviceIDs: [UInt32])] = []
        for jid in memberJIDs where jid != ownJID {
            let deviceIDs = await trustedDeviceIDs(for: jid, accountID: accountID)
            if !deviceIDs.isEmpty {
                recipients.append((jid: jid, deviceIDs: deviceIDs))
            }
        }
        return recipients
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

    private func handleSessionEstablished(
        jid: BareJID, deviceID: UInt32,
        identityKey: [UInt8], accountID: UUID
    ) async {
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

// MARK: - Errors

enum OMEMOServiceError: Error {
    case notConnected
    case omemoNotAvailable
    case noTrustedRecipients
    case identityKeyMismatch
    case identityKeyUntrusted
}

// periphery:ignore - specced feature, used by validateRoomForOMEMO
public struct RoomOMEMOValidation: Sendable {
    public let membersWithoutOMEMO: [String]
    public let totalMembers: Int
    public let encryptableMembers: Int
}
