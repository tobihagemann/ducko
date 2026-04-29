import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.omemo")

/// Implements XEP-0384 OMEMO Encryption and XEP-0380 Explicit Message Encryption.
///
/// Manages device lists, bundles, session establishment (X3DH), and
/// per-message encryption/decryption (Double Ratchet + AES-256-CBC).
/// Uses PEPModule for all PubSub operations.
public final class OMEMOModule: XMPPModule, Sendable {
    // MARK: - State

    private struct SessionEntry {
        var session: OMEMODoubleRatchetSession
        var associatedData: [UInt8]
    }

    private struct State {
        var context: ModuleContext?
        var deviceLists: [BareJID: [UInt32]] = [:]
        var ownIdentity: OwnIdentity?
        var pendingIdentity: OMEMOIdentityData?
        var sessions: [SessionKey: SessionEntry] = [:]
        var usedPreKeyIDs: Set<UInt32> = []
        var identityKeyValidator: (@Sendable (BareJID, UInt32, [UInt8]) async throws -> Void)?
        /// Provider of the per-account previously-seen-device-IDs set used by
        /// `pruneStaleBundles` to gate auto-retract on a prior observation.
        /// Stored on the service rather than the module so the set survives
        /// reconnects (modules are rebuilt per reconnect; the service is held
        /// by `AppEnvironment` and outlives them). Identifier is an opaque
        /// String (the service's `UUID.uuidString` in production) so this
        /// file does not need to import Foundation.
        var previouslySeenDeviceIDsProvider: (any PreviouslySeenDeviceIDsProviding)?
        var previouslySeenAccountID: String?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let pepModule: PEPModule

    /// PEP node name prefix for OMEMO bundle nodes (XEP-0384). A device's
    /// bundle is published at `bundleNodePrefix + "<deviceID>"`.
    public static let bundleNodePrefix = "\(XMPPNamespaces.omemo):bundles:"

    public var features: [String] {
        [XMPPNamespaces.omemo, XMPPNamespaces.eme]
    }

    public init(pepModule: PEPModule) {
        self.pepModule = pepModule
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    // MARK: - XMPPModule

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    public func handleConnect() async throws {
        let identity: OwnIdentity
        if let pending = state.withLock({ $0.pendingIdentity }) {
            identity = try restoreIdentity(from: pending)
            state.withLock {
                $0.pendingIdentity = nil
                $0.ownIdentity = identity
            }
        } else {
            identity = try generateOwnIdentity()
            state.withLock { $0.ownIdentity = identity }
        }
        try await ensureOwnDeviceInList(identity.deviceID)
        try await publishOwnBundle(identity)
        let deviceID = identity.deviceID.value
        log.info("OMEMO setup complete, device ID: \(deviceID)")

        // Best-effort defense-in-depth pass against PEP entries whose bundles
        // are missing — never aborts the connect chain.
        let ownList = state.withLock { $0.deviceLists[identity.connectedJID.bareJID] ?? [deviceID] }
        do {
            _ = try await pruneStaleBundles(ownDeviceID: deviceID, ownDeviceList: ownList)
        } catch let stanzaError as XMPPStanzaError {
            log.warning("OMEMO stale-bundle pruning failed: \(stanzaError.condition.rawValue)")
        } catch {
            log.warning("OMEMO stale-bundle pruning failed")
            log.debug("OMEMO stale-bundle pruning failed: \(error)")
        }
    }

    public func handleDisconnect() async {
        state.withLock {
            $0.ownIdentity = nil
            $0.deviceLists.removeAll()
            $0.sessions.removeAll()
            $0.usedPreKeyIDs.removeAll()
            $0.identityKeyValidator = nil
            $0.previouslySeenDeviceIDsProvider = nil
            $0.previouslySeenAccountID = nil
        }
    }

    public func handleMessage(_ message: XMPPMessage) throws {
        handleDeviceListNotification(message)
        handleEncryptedMessage(message)
    }

    // MARK: - Public API

    /// Exports the current identity as serializable data for persistence.
    public var ownIdentityData: OMEMOIdentityData? {
        state.withLock { state in
            guard let identity = state.ownIdentity else { return nil }
            return OMEMOIdentityData(
                deviceID: identity.deviceID.value,
                identityKeyRaw: identity.identityKeyPair.rawRepresentation,
                signedPreKeyID: identity.signedPreKey.keyID,
                signedPreKeyRaw: identity.signedPreKey.rawRepresentation,
                signedPreKeySignature: identity.signedPreKey.signature,
                preKeys: identity.preKeys.map {
                    OMEMOIdentityData.PreKeyData(keyID: $0.keyID, keyRaw: $0.rawRepresentation)
                }
            )
        }
    }

    /// Pre-configures identity data to be used on next `handleConnect()` instead of generating fresh.
    public func configureIdentity(_ data: OMEMOIdentityData) {
        state.withLock { $0.pendingIdentity = data }
    }

    /// Sets a callback invoked during session establishment to verify the peer's identity key.
    ///
    /// The validator receives `(peerJID, deviceID, identityKey)` and should throw
    /// if the key is untrusted or mismatched. Called before X3DH key agreement.
    public func setIdentityKeyValidator(
        _ validator: (@Sendable (BareJID, UInt32, [UInt8]) async throws -> Void)?
    ) {
        state.withLock { $0.identityKeyValidator = validator }
    }

    /// Wires the previously-seen-device-IDs provider used by
    /// ``pruneStaleBundles(ownDeviceID:ownDeviceList:)`` to gate auto-retract
    /// on a prior observation. The provider is shared per-account by
    /// `OMEMOService`, which holds the set across reconnects.
    package func configurePreviouslySeenDeviceIDsProvider(
        _ provider: any PreviouslySeenDeviceIDsProviding,
        accountID: String
    ) {
        state.withLock {
            $0.previouslySeenDeviceIDsProvider = provider
            $0.previouslySeenAccountID = accountID
        }
    }

    /// Returns the set of pre-key IDs consumed during this session.
    public func consumedPreKeyIDs() -> Set<UInt32> {
        state.withLock { $0.usedPreKeyIDs }
    }

    /// Restores previously persisted sessions into the module's in-memory state.
    public func restoreSessions(_ entries: [StoredSessionEntry]) {
        state.withLock { state in
            for entry in entries {
                let key = SessionKey(jid: entry.jid, deviceID: entry.deviceID)
                if let session = try? OMEMODoubleRatchetSession(serialized: entry.sessionData) {
                    state.sessions[key] = SessionEntry(
                        session: session, associatedData: entry.associatedData
                    )
                }
            }
        }
    }

    /// Exports a single session's state for persistent storage.
    public func exportSession(jid: BareJID, deviceID: UInt32) -> StoredSessionEntry? {
        state.withLock { state in
            let key = SessionKey(jid: jid, deviceID: deviceID)
            guard let entry = state.sessions[key] else { return nil }
            return StoredSessionEntry(
                jid: jid, deviceID: deviceID,
                sessionData: entry.session.serialize(), associatedData: entry.associatedData
            )
        }
    }

    /// Exports all sessions for persistent storage (e.g., on disconnect).
    public func allSessionEntries() -> [StoredSessionEntry] {
        state.withLock { state in
            state.sessions.map { key, entry in
                StoredSessionEntry(
                    jid: key.jid, deviceID: key.deviceID,
                    sessionData: entry.session.serialize(), associatedData: entry.associatedData
                )
            }
        }
    }

    /// Fetches device IDs for a JID. Returns the cached list when available;
    /// pass `forceRefresh: true` to bypass the cache and pull from PEP.
    ///
    /// A forced refresh updates the module cache and emits
    /// `.omemoDeviceListReceived` so downstream services (trust store, UI)
    /// observe the new list exactly as they would for a +notify. Without a
    /// force, the cache hit path is silent — callers that need the store to
    /// reflect the peer's current publish must opt into a refresh.
    public func fetchDeviceList(
        for jid: BareJID, forceRefresh: Bool = false
    ) async throws -> [UInt32] {
        if !forceRefresh, let cached = state.withLock({ $0.deviceLists[jid] }) {
            return cached
        }
        let devices = try await fetchDeviceListFromPEP(jid)
        let context = state.withLock { state in
            state.deviceLists[jid] = devices
            return state.context
        }
        if forceRefresh {
            context?.emitEvent(.omemoDeviceListReceived(jid: jid, devices: devices))
        }
        return devices
    }

    /// Encrypts a message for the recipient's devices.
    ///
    /// - Parameters:
    ///   - plaintext: Message body to encrypt.
    ///   - recipientJID: The recipient's bare JID.
    ///   - recipientDeviceIDs: Specific device IDs to encrypt for, or `nil` to encrypt for all known devices.
    ///   - ownDeviceIDs: Specific own device IDs to encrypt for, or `nil` to encrypt for all own devices.
    public func encryptMessage(
        plaintext: String,
        to recipientJID: BareJID,
        recipientDeviceIDs: [UInt32]? = nil,
        ownDeviceIDs: [UInt32]? = nil
    ) async throws -> EncryptedMessageElements {
        let recipientDevices: [UInt32] = if let recipientDeviceIDs {
            recipientDeviceIDs
        } else {
            try await fetchDeviceList(for: recipientJID)
        }
        return try await encryptForDevices(
            plaintext: plaintext,
            peerDevices: recipientDevices.map { (jid: recipientJID, deviceID: $0) },
            ownDeviceIDs: ownDeviceIDs,
            conversation: recipientJID
        )
    }

    /// Encrypts a message for multiple recipients (group chat OMEMO).
    ///
    /// - Parameters:
    ///   - plaintext: Message body to encrypt.
    ///   - roomJID: The MUC bare JID; used to label `omemoRecipientsPartial`
    ///     events for downstream correlation.
    ///   - recipients: Per-recipient JID and device IDs.
    ///   - ownDeviceIDs: Specific own device IDs to encrypt for, or `nil` to encrypt for all own devices.
    public func encryptGroupMessage(
        plaintext: String,
        roomJID: BareJID,
        recipients: [(jid: BareJID, deviceIDs: [UInt32])],
        ownDeviceIDs: [UInt32]? = nil
    ) async throws -> EncryptedMessageElements {
        let peerDevices = recipients.flatMap { r in r.deviceIDs.map { (jid: r.jid, deviceID: $0) } }
        return try await encryptForDevices(
            plaintext: plaintext,
            peerDevices: peerDevices,
            ownDeviceIDs: ownDeviceIDs,
            conversation: roomJID
        )
    }

    /// Shared encrypt pipeline for 1:1 and group OMEMO sends. Throws
    /// `noUsableRecipientDevices` when every peer device's bundle was
    /// missing — covers both the "PEP list empty" case and the "every
    /// listed device returned item-not-found" case, which are otherwise
    /// indistinguishable from a lost message to the recipient. `conversation`
    /// labels the emitted `omemoRecipientsPartial` event (peer JID for 1:1,
    /// room JID for group).
    private func encryptForDevices(
        plaintext: String,
        peerDevices: [(jid: BareJID, deviceID: UInt32)],
        ownDeviceIDs: [UInt32]?,
        conversation: BareJID
    ) async throws -> EncryptedMessageElements {
        let identity = try requireOwnIdentity()
        let contentKey = randomBytes(32)
        let sceBytes = buildSCEEnvelope(body: plaintext)
        let payload = try encryptPayload(sceBytes, contentKey: contentKey)
        let peerEncryption = try await encryptKeysInParallel(
            contentKey: contentKey, identity: identity, devices: peerDevices
        )
        var results = peerEncryption.results
        if results.isEmpty {
            // Surface the dropped peer devices before throwing so operators
            // see the same diagnostic in the worst case (every recipient
            // device unfetchable) as in partial-coverage cases. The throw
            // would otherwise hide the dropped set entirely.
            emitDroppedRecipientsEventIfNeeded(
                conversation: conversation, dropped: peerEncryption.dropped
            )
            throw OMEMOModuleError.noUsableRecipientDevices
        }
        let ownEncryption = try await encryptKeyForOwnDevices(
            contentKey: contentKey, identity: identity, ownDeviceIDs: ownDeviceIDs
        )
        results += ownEncryption.results
        applySessionUpdates(results)
        let keys = results.map(\.keyElement)
        let droppedRecipients = peerEncryption.dropped + ownEncryption.dropped
        let elements = buildEncryptedElements(
            keys: keys, payload: payload, senderDeviceID: identity.deviceID.value,
            droppedRecipients: droppedRecipients
        )
        emitDroppedRecipientsEventIfNeeded(conversation: conversation, dropped: droppedRecipients)
        return elements
    }

    private struct EncryptionResult {
        let keyElement: XMLElement
        let sessionKey: SessionKey
        let updatedEntry: SessionEntry
    }

    /// Bulk result of encrypting a content key for many devices: successful
    /// per-device key elements plus the subset that was skipped because no
    /// bundle could be fetched. The dropped subset is what `encryptMessage` /
    /// `encryptGroupMessage` need to surface via `omemoRecipientsPartial`.
    private struct EncryptionBatch {
        var results: [EncryptionResult]
        var dropped: [DroppedOMEMORecipient]
    }

    private func encryptKeysInParallel(
        contentKey: [UInt8], identity: OwnIdentity,
        devices: [(jid: BareJID, deviceID: UInt32)]
    ) async throws -> EncryptionBatch {
        assert(
            Set(devices.map { SessionKey(jid: $0.jid, deviceID: $0.deviceID) }).count == devices.count,
            "Duplicate devices would corrupt Double Ratchet sessions"
        )
        // XEP-0384 §5.4: A device listed without a published bundle is not an
        // error state — skip it instead of aborting the whole send. Guards the
        // sender against stale PEP device-list entries whose bundle was never
        // (or no longer) published.
        enum Outcome: Sendable {
            case encrypted(EncryptionResult)
            case dropped(DroppedOMEMORecipient)
        }
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            for device in devices {
                group.addTask {
                    do {
                        let result = try await self.encryptKeyForDevice(
                            contentKey: contentKey, jid: device.jid,
                            deviceID: device.deviceID, identity: identity
                        )
                        return .encrypted(result)
                    } catch OMEMOModuleError.bundleNotFound {
                        log.debug(
                            "OMEMO: skipping \(device.jid)/\(device.deviceID) — bundle not found"
                        )
                        return .dropped(DroppedOMEMORecipient(jid: device.jid, deviceID: device.deviceID))
                    } catch let stanzaError as XMPPStanzaError
                        where stanzaError.condition == .itemNotFound {
                        log.debug(
                            "OMEMO: skipping \(device.jid)/\(device.deviceID) — item-not-found"
                        )
                        return .dropped(DroppedOMEMORecipient(jid: device.jid, deviceID: device.deviceID))
                    }
                }
            }
            var batch = EncryptionBatch(results: [], dropped: [])
            for try await outcome in group {
                switch outcome {
                case let .encrypted(result):
                    batch.results.append(result)
                case let .dropped(drop):
                    batch.dropped.append(drop)
                }
            }
            return batch
        }
    }

    private func encryptKeyForOwnDevices(
        contentKey: [UInt8], identity: OwnIdentity,
        ownDeviceIDs: [UInt32]?
    ) async throws -> EncryptionBatch {
        let ownJID = identity.connectedJID.bareJID
        let ownDevices: [UInt32] = if let ownDeviceIDs {
            ownDeviceIDs
        } else {
            try await fetchDeviceList(for: ownJID)
        }
        let filtered = ownDevices.filter { $0 != identity.deviceID.value }
        return try await encryptKeysInParallel(
            contentKey: contentKey, identity: identity,
            devices: filtered.map { (jid: ownJID, deviceID: $0) }
        )
    }

    private func emitDroppedRecipientsEventIfNeeded(
        conversation: BareJID, dropped: [DroppedOMEMORecipient]
    ) {
        guard !dropped.isEmpty else { return }
        let context = state.withLock { $0.context }
        context?.emitEvent(.omemoRecipientsPartial(conversation: conversation, droppedDevices: dropped))
    }

    private func applySessionUpdates(_ results: [EncryptionResult]) {
        let updates = results.map { ($0.sessionKey, $0.updatedEntry) }
        state.withLock { state in
            for (key, entry) in updates {
                state.sessions[key] = entry
            }
        }
    }

    private func buildEncryptedElements(
        keys: [XMLElement], payload: String,
        senderDeviceID: UInt32,
        droppedRecipients: [DroppedOMEMORecipient]
    ) -> EncryptedMessageElements {
        let encrypted = buildEncryptedElement(
            keys: keys, payload: payload, senderDeviceID: senderDeviceID
        )
        let encryption = XMLElement(
            name: "encryption",
            namespace: XMPPNamespaces.eme,
            attributes: ["namespace": XMPPNamespaces.omemo, "name": "OMEMO"]
        )
        return EncryptedMessageElements(
            encrypted: encrypted,
            encryption: encryption,
            fallbackBody: "This message is OMEMO encrypted",
            droppedRecipients: droppedRecipients
        )
    }

    // MARK: - Identity Generation

    private func restoreIdentity(from data: OMEMOIdentityData) throws -> OwnIdentity {
        let context = state.withLock { $0.context }
        guard let connectedJID = context?.connectedJID() else {
            throw OMEMOModuleError.notSetUp
        }
        let identityKeyPair = try OMEMOIdentityKeyPair(rawRepresentation: data.identityKeyRaw)
        let signedPreKey = try OMEMOSignedPreKey(
            keyID: data.signedPreKeyID,
            rawRepresentation: data.signedPreKeyRaw,
            signature: data.signedPreKeySignature
        )
        let preKeys = try data.preKeys.map {
            try OMEMOPreKey(keyID: $0.keyID, rawRepresentation: $0.keyRaw)
        }
        return OwnIdentity(
            deviceID: OMEMODeviceID(value: data.deviceID),
            identityKeyPair: identityKeyPair,
            signedPreKey: signedPreKey,
            preKeys: preKeys,
            connectedJID: connectedJID
        )
    }

    private func generateOwnIdentity() throws -> OwnIdentity {
        let deviceID = OMEMODeviceID.random()
        let identityKeyPair = OMEMOIdentityKeyPair()
        let signedPreKey = try OMEMOPreKeyManager.generateSignedPreKey(
            keyID: 1, identityKey: identityKeyPair
        )
        let preKeys = OMEMOPreKeyManager.generatePreKeys(
            startID: 1, count: OMEMOPreKeyManager.targetPreKeyCount
        )
        let context = state.withLock { $0.context }
        guard let connectedJID = context?.connectedJID() else {
            throw OMEMOModuleError.notSetUp
        }
        return OwnIdentity(
            deviceID: deviceID,
            identityKeyPair: identityKeyPair,
            signedPreKey: signedPreKey,
            preKeys: preKeys,
            connectedJID: connectedJID
        )
    }

    private func requireOwnIdentity() throws -> OwnIdentity {
        guard let identity = state.withLock({ $0.ownIdentity }) else {
            throw OMEMOModuleError.notSetUp
        }
        return identity
    }

    // MARK: - Device List Management

    private func ensureOwnDeviceInList(
        _ deviceID: OMEMODeviceID
    ) async throws {
        var devices: [UInt32]
        do {
            devices = try await fetchDeviceListFromPEP(nil)
        } catch {
            devices = []
        }
        if !devices.contains(deviceID.value) {
            devices.append(deviceID.value)
            try await publishDeviceList(devices)
        }
        let finalDevices = devices
        state.withLock {
            if let ownJID = $0.context?.connectedJID()?.bareJID {
                $0.deviceLists[ownJID] = finalDevices
            }
        }
    }

    private func fetchDeviceListFromPEP(
        _ jid: BareJID?
    ) async throws -> [UInt32] {
        let items = try await pepModule.retrieveItems(
            node: XMPPNamespaces.omemoDevices, from: jid
        )
        guard let item = items.first else { return [] }
        return parseDeviceList(item.payload)
    }

    private func publishDeviceList(
        _ devices: [UInt32]
    ) async throws {
        let payload = buildDeviceListElement(devices)
        try await pepModule.publishItem(
            node: XMPPNamespaces.omemoDevices,
            itemID: "current",
            payload: payload,
            options: pepPublishOptions(maxItems: 1)
        )
    }

    // MARK: - Bundle Management

    /// Item ID used for both publishing and retracting OMEMO bundles. Single
    /// constant so the publish and retract sites cannot drift to different
    /// IDs (a wrong itemID is a silent no-op on most PEP servers).
    private static let bundleItemID = "current"

    private func publishOwnBundle(
        _ identity: OwnIdentity
    ) async throws {
        let bundle = OMEMOPreKeyManager.buildBundle(
            deviceID: identity.deviceID,
            identityKeyPair: identity.identityKeyPair,
            signedPreKey: identity.signedPreKey,
            preKeys: identity.preKeys
        )
        let payload = buildBundleElement(bundle)
        let node = bundleNodeName(identity.deviceID.value)
        try await pepModule.publishItem(
            node: node, itemID: Self.bundleItemID,
            payload: payload, options: pepPublishOptions()
        )
    }

    // MARK: - Stale Bundle Pruning

    private enum BundleClassification {
        case stale
        case healthy
        case transient
    }

    /// Maximum number of peer deviceIDs to probe in a single prune cycle.
    /// A malicious or compromised PEP server can return an arbitrarily large
    /// own-device list; without a cap, every reconnect would issue thousands
    /// of bundle-probe IQs, blocking connect and saturating logs/network.
    /// 64 is generous for any realistic legitimate user (own devices on one
    /// account) and small enough to bound the worst case.
    private static let pruneProbeCap = 64

    /// Probes each peer device's bundle on the published own-device list and
    /// (when a prior observation is recorded for that device) auto-retracts
    /// orphan bundle nodes so siblings cannot be addressed via dead deviceIDs.
    ///
    /// - Parameters:
    ///   - ownDeviceID: This client's device ID; never probed/retracted.
    ///   - ownDeviceList: The current device-list contents at PEP.
    /// - Returns: The (possibly trimmed) device list. The list is only
    ///   trimmed for IDs that classified as `.stale` AND were
    ///   previously-observed; first-connect-after-launch finds an empty
    ///   seen-set and warn-only logs every stale device.
    /// - Throws: Only when the post-pruning `publishDeviceList(_:)` re-publish
    ///   fails. Per-device probe failures are swallowed (logged at
    ///   `.warning`) so a transient PEP error never aborts the connect chain.
    private func pruneStaleBundles(
        ownDeviceID: UInt32, ownDeviceList: [UInt32]
    ) async throws -> [UInt32] {
        let peerDeviceIDs = ownDeviceList.filter { $0 != ownDeviceID }
        let (provider, accountID) = state.withLock {
            ($0.previouslySeenDeviceIDsProvider, $0.previouslySeenAccountID)
        }
        // Always anchor the seen-set to whatever PEP currently lists, even
        // when there's nothing to probe — otherwise a list that shrinks then
        // re-grows with the same orphan ID would auto-retract on the very
        // first observation in the new epoch, violating the prior-observation
        // gate's invariant.
        guard !peerDeviceIDs.isEmpty else {
            if let provider, let accountID {
                await provider.updatePreviouslySeenDeviceIDs(Set(ownDeviceList), accountID: accountID)
            }
            return ownDeviceList
        }

        // Resource-exhaustion guard against a hostile server: skip pruning
        // when the list is implausibly large rather than firing thousands of
        // probes. The seen-set still anchors to the full list so a future
        // shrink-then-regrow doesn't bypass the prior-observation gate.
        if peerDeviceIDs.count > Self.pruneProbeCap {
            log.warning("OMEMO device list has \(peerDeviceIDs.count) peer devices, exceeding probe cap; skipping prune")
            if let provider, let accountID {
                await provider.updatePreviouslySeenDeviceIDs(Set(ownDeviceList), accountID: accountID)
            }
            return ownDeviceList
        }

        let classifications = await classifyBundleProbes(deviceIDs: peerDeviceIDs)
        let staleIDs = classifications.filter { $0.classification == .stale }.map(\.id)

        // Concurrent-publish race guard: only retract when we have evidence
        // that the orphan was already on the list at a prior observation.
        // Without this gate, two clients connecting simultaneously could
        // mis-classify each other's freshly-listed deviceID as stale and
        // retract a sibling. First connect after `OMEMOService` is built has
        // an empty seen-set; auto-retract kicks in on subsequent reconnects
        // within the service's lifetime.
        let previouslySeen: Set<UInt32> = if let provider, let accountID {
            await provider.previouslySeenDeviceIDs(accountID: accountID)
        } else {
            []
        }
        let retractIDs = staleIDs.filter { previouslySeen.contains($0) }

        // Always log first-observation orphans, even when the retract path
        // also fires for sibling IDs in the same prune cycle. Without this,
        // mixed `staleIDs = {previouslySeen, unseen}` cases would silently
        // drop the operator-visible "first observed" log line for the unseen
        // half (they'd be retracted on the next reconnect, but the audit
        // trail for this reconnect would be incomplete).
        for id in staleIDs where !previouslySeen.contains(id) {
            log.warning("OMEMO stale bundle observed for device \(id) — will auto-retract on next reconnect if still missing")
        }

        if !retractIDs.isEmpty {
            return try await retractAndRePublish(
                retractIDs: retractIDs, ownDeviceList: ownDeviceList,
                provider: provider, accountID: accountID
            )
        }

        if let provider, let accountID {
            await provider.updatePreviouslySeenDeviceIDs(Set(ownDeviceList), accountID: accountID)
        }
        return ownDeviceList
    }

    /// Probes each peer device's bundle node and classifies the response.
    /// Caps concurrency at 4 by chunking — `withTaskGroup` does not have a
    /// built-in concurrency limiter but slicing into windows of 4 achieves
    /// the same effect with no extra primitives.
    private func classifyBundleProbes(
        deviceIDs: [UInt32]
    ) async -> [(id: UInt32, classification: BundleClassification)] {
        let chunkSize = 4
        var classifications: [(id: UInt32, classification: BundleClassification)] = []
        classifications.reserveCapacity(deviceIDs.count)
        for chunkStart in stride(from: 0, to: deviceIDs.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, deviceIDs.count)
            let chunk = deviceIDs[chunkStart ..< chunkEnd]
            let chunkResults = await withTaskGroup(
                of: (id: UInt32, classification: BundleClassification).self
            ) { group in
                for id in chunk {
                    group.addTask {
                        await self.probeBundle(deviceID: id)
                    }
                }
                var collected: [(id: UInt32, classification: BundleClassification)] = []
                for await pair in group {
                    collected.append(pair)
                }
                return collected
            }
            classifications.append(contentsOf: chunkResults)
        }
        return classifications
    }

    /// Classifies a peer device's bundle. Only `item-not-found` and
    /// successfully-parsed-as-empty responses count as `.stale`; an empty
    /// `<items/>` list is ambiguous (e.g. a hostile or replicating server
    /// answering empty for a live bundle), so it falls into `.transient`. A
    /// listed bundle item whose payload fails `parseBundleElement` would be
    /// `bundleNotFound` to the encrypt path, so we classify it as `.stale`
    /// here for symmetry.
    private func probeBundle(
        deviceID: UInt32
    ) async -> (id: UInt32, classification: BundleClassification) {
        do {
            let items = try await pepModule.retrieveItems(
                node: bundleNodeName(deviceID), from: nil, maxItems: 1
            )
            guard let item = items.first else {
                return (id: deviceID, classification: .transient)
            }
            if parseBundleElement(item.payload, deviceID: deviceID) == nil {
                return (id: deviceID, classification: .stale)
            }
            return (id: deviceID, classification: .healthy)
        } catch let stanzaError as XMPPStanzaError where stanzaError.condition == .itemNotFound {
            return (id: deviceID, classification: .stale)
        } catch let stanzaError as XMPPStanzaError {
            log.warning("OMEMO bundle probe failed for device \(deviceID): \(stanzaError.condition.rawValue)")
            return (id: deviceID, classification: .transient)
        } catch {
            log.warning("OMEMO bundle probe failed for device \(deviceID)")
            log.debug("OMEMO bundle probe failed for device \(deviceID): \(error)")
            return (id: deviceID, classification: .transient)
        }
    }

    /// Re-publishes the trimmed device list FIRST so a subsequent retract
    /// failure leaves PEP no worse off — a future `fetchBundle` on a
    /// still-orphan bundle is harmless because the device list no longer
    /// names it. After re-publish, retracts each orphan bundle, then updates
    /// in-memory cache and the seen-set.
    private func retractAndRePublish(
        retractIDs: [UInt32], ownDeviceList: [UInt32],
        provider: (any PreviouslySeenDeviceIDsProviding)?,
        accountID: String?
    ) async throws -> [UInt32] {
        let trimmedList = ownDeviceList.filter { !retractIDs.contains($0) }
        try await publishDeviceList(trimmedList)
        for id in retractIDs {
            do {
                try await pepModule.retractItem(
                    node: bundleNodeName(id), itemID: Self.bundleItemID
                )
            } catch let stanzaError as XMPPStanzaError {
                log.warning("OMEMO bundle retract failed for device \(id): \(stanzaError.condition.rawValue)")
            } catch {
                log.warning("OMEMO bundle retract failed for device \(id)")
                log.debug("OMEMO bundle retract failed for device \(id): \(error)")
            }
        }
        let connectedJID = state.withLock { $0.context?.connectedJID()?.bareJID }
        if let connectedJID {
            state.withLock { $0.deviceLists[connectedJID] = trimmedList }
        }
        if let provider, let accountID {
            await provider.updatePreviouslySeenDeviceIDs(Set(trimmedList), accountID: accountID)
        }
        log.info("OMEMO pruned \(retractIDs.count) stale bundle(s)")
        return trimmedList
    }

    private func fetchBundle(
        from jid: BareJID, deviceID: UInt32
    ) async throws -> OMEMOBundle {
        let node = bundleNodeName(deviceID)
        let items = try await pepModule.retrieveItems(
            node: node, from: jid
        )
        guard let item = items.first,
              let bundle = parseBundleElement(
                  item.payload, deviceID: deviceID
              )
        else {
            throw OMEMOModuleError.bundleNotFound
        }
        return bundle
    }

    // MARK: - Message Handling

    private func handleDeviceListNotification(
        _ message: XMPPMessage
    ) {
        guard let event = message.element.child(
            named: "event", namespace: XMPPNamespaces.pubsubEvent
        ) else { return }
        guard let itemsEl = event.child(named: "items"),
              itemsEl.attribute("node") == XMPPNamespaces.omemoDevices
        else { return }
        guard let from = message.from?.bareJID else { return }
        guard let item = itemsEl.child(named: "item"),
              let payload = item.children.compactMap({
                  if case let .element(el) = $0 { return el }
                  return nil
              }).first
        else { return }
        let devices = parseDeviceList(payload)
        let context = state.withLock {
            $0.deviceLists[from] = devices
            return $0.context
        }
        context?.emitEvent(
            .omemoDeviceListReceived(jid: from, devices: devices)
        )
    }

    private func handleEncryptedMessage(_ message: XMPPMessage) {
        guard let encrypted = message.element.child(
            named: "encrypted", namespace: XMPPNamespaces.omemo
        ) else { return }
        guard let from = message.from else { return }

        // Extract XEP-0359 stanza-id for dedup and marker correlation
        let stanzaID = message.element
            .child(named: "stanza-id", namespace: XMPPNamespaces.stanzaID)?
            .attribute("id")

        do {
            let result = try decryptIncomingMessage(
                encrypted, from: from
            )
            let context = state.withLock { $0.context }

            // XEP-0308: Encrypted correction
            if let replace = message.element.child(named: "replace", namespace: XMPPNamespaces.messageCorrect),
               let originalID = replace.attribute("id"),
               let body = result.body {
                context?.emitEvent(.messageCorrected(originalID: originalID, newBody: body, from: from))
                context?.emitEvent(.omemoSessionAdvanced(jid: from.bareJID, deviceID: result.senderDeviceID))
                return
            }

            // XEP-0424: Encrypted retraction
            if let retract = message.element.child(named: "retract", namespace: XMPPNamespaces.messageRetract),
               let originalID = retract.attribute("id") {
                context?.emitEvent(.messageRetracted(originalID: originalID, from: from))
                context?.emitEvent(.omemoSessionAdvanced(jid: from.bareJID, deviceID: result.senderDeviceID))
                return
            }

            // Regular encrypted message
            context?.emitEvent(.omemoEncryptedMessageReceived(
                from: from,
                decryptedBody: result.body,
                senderDeviceID: result.senderDeviceID,
                stanzaID: stanzaID
            ))
        } catch OMEMOModuleError.notForThisDevice {
            // Not addressed to us — ignore silently
        } catch {
            log.warning("OMEMO decryption failed: \(error)")
            let context = state.withLock { $0.context }
            context?.emitEvent(.omemoEncryptedMessageReceived(
                from: from, decryptedBody: nil, senderDeviceID: 0,
                stanzaID: stanzaID
            ))
        }
    }

    // MARK: - Decryption

    private func decryptIncomingMessage(
        _ encrypted: XMLElement, from: JID
    ) throws -> DecryptionResult {
        let header = try parseHeader(encrypted)
        let ownDeviceID = state.withLock {
            $0.ownIdentity?.deviceID.value
        }
        guard let ownDeviceID else {
            throw OMEMOModuleError.notSetUp
        }
        guard let keyElement = findKeyElement(
            header.element, rid: ownDeviceID
        ) else {
            throw OMEMOModuleError.notForThisDevice
        }
        let isKex = keyElement.attribute("kex") == "true"
        guard let keyText = keyElement.textContent,
              let keyData = Base64.decode(keyText)
        else {
            throw OMEMOModuleError.invalidKeyData
        }
        let senderJID = from.bareJID
        let sessionKey = SessionKey(
            jid: senderJID, deviceID: header.sid
        )
        let contentKey: [UInt8] = if isKex {
            try decryptKexKey(
                keyData, sessionKey: sessionKey, header: header
            )
        } else {
            try decryptExistingSessionKey(
                keyData, sessionKey: sessionKey
            )
        }
        let body = try decryptPayload(encrypted, contentKey: contentKey)
        return DecryptionResult(
            body: body, senderDeviceID: header.sid
        )
    }

    private func decryptKexKey(
        _ data: [UInt8], sessionKey: SessionKey,
        header: ParsedHeader
    ) throws -> [UInt8] {
        let kex = try deserializeKeyExchange(data)
        let identity = try requireOwnIdentity()
        guard kex.signedPreKeyID == identity.signedPreKey.keyID else {
            throw OMEMOModuleError.invalidKeyData
        }
        let preKey = identity.preKeys.first {
            $0.keyID == kex.preKeyID
        }
        let x3dhResult = try OMEMOX3DH.responderKeyAgreement(
            identityKeyPair: identity.identityKeyPair,
            signedPreKey: identity.signedPreKey,
            oneTimePreKey: preKey,
            peerIdentityKey: kex.identityKey,
            peerEphemeralKey: kex.ephemeralKey
        )
        var session = OMEMODoubleRatchetSession(
            asResponderWithSharedSecret: x3dhResult.sharedSecret,
            ourSignedPreKeyPair: identity.signedPreKey.keyPair
        )
        let plaintext = try session.decrypt(
            message: kex.ratchetMessage,
            associatedData: x3dhResult.associatedData
        )
        let updatedSession = session
        let ad = x3dhResult.associatedData
        let consumedPreKeyID = preKey?.keyID
        let context = state.withLock {
            $0.sessions[sessionKey] = SessionEntry(
                session: updatedSession, associatedData: ad
            )
            if let consumedPreKeyID {
                $0.usedPreKeyIDs.insert(consumedPreKeyID)
            }
            if let knownDevices = $0.deviceLists[sessionKey.jid],
               !knownDevices.contains(header.sid) {
                log.warning("KEX from unannounced device \(header.sid) for \(sessionKey.jid)")
            }
            return $0.context
        }
        context?.emitEvent(.omemoSessionEstablished(
            jid: sessionKey.jid, deviceID: sessionKey.deviceID,
            identityKey: kex.identityKey
        ))
        return plaintext
    }

    private func decryptExistingSessionKey(
        _ data: [UInt8], sessionKey: SessionKey
    ) throws -> [UInt8] {
        let ratchetMessage = try deserializeRatchetMessage(data)
        guard var entry = state.withLock({ $0.sessions[sessionKey] }) else {
            throw OMEMOModuleError.noSession
        }
        let plaintext = try entry.session.decrypt(
            message: ratchetMessage, associatedData: entry.associatedData
        )
        let updatedEntry = entry
        state.withLock { $0.sessions[sessionKey] = updatedEntry }
        return plaintext
    }

    private func decryptPayload(
        _ encrypted: XMLElement, contentKey: [UInt8]
    ) throws -> String? {
        guard let payloadEl = encrypted.child(named: "payload"),
              let payloadText = payloadEl.textContent,
              let payloadData = Base64.decode(payloadText)
        else {
            return nil // Key transport message — no payload
        }
        guard payloadData.count > 16 else {
            throw OMEMOModuleError.invalidPayload
        }
        let ciphertext = Array(payloadData.dropLast(16))
        let hmac = Array(payloadData.suffix(16))
        let payload = OMEMOEncryptedPayload(
            ciphertext: ciphertext, truncatedHMAC: hmac
        )
        let sceBytes = try OMEMOMessageCrypto.decrypt(
            payload: payload, messageKey: contentKey,
            associatedData: []
        )
        return parseSCEBody(sceBytes)
    }

    // MARK: - Encryption

    private func encryptPayload(
        _ plaintext: [UInt8], contentKey: [UInt8]
    ) throws -> String {
        let encrypted = try OMEMOMessageCrypto.encrypt(
            plaintext: plaintext, messageKey: contentKey,
            associatedData: []
        )
        let combined = encrypted.ciphertext + encrypted.truncatedHMAC
        return Base64.encode(combined)
    }

    private func encryptKeyForDevice(
        contentKey: [UInt8], jid: BareJID,
        deviceID: UInt32, identity: OwnIdentity
    ) async throws -> EncryptionResult {
        let sessionKey = SessionKey(jid: jid, deviceID: deviceID)
        let result = try await getOrEstablishSession(
            sessionKey: sessionKey, identity: identity
        )
        var mutableSession = result.session
        let ratchetMessage = try mutableSession.encrypt(
            plaintext: contentKey, associatedData: result.ad
        )
        let updatedEntry = SessionEntry(
            session: mutableSession, associatedData: result.ad
        )
        let serialized: [UInt8]
        let isKex: Bool
        if let kexInfo = result.kexInfo {
            serialized = serializeKeyExchange(
                ratchetMessage: ratchetMessage,
                identity: identity, kexInfo: kexInfo
            )
            isKex = true
        } else {
            serialized = serializeRatchetMessage(ratchetMessage)
            isKex = false
        }
        let keyElement = buildKeyElement(
            deviceID: deviceID, data: serialized, isKex: isKex
        )
        return EncryptionResult(
            keyElement: keyElement, sessionKey: sessionKey,
            updatedEntry: updatedEntry
        )
    }

    // MARK: - Session Management

    private func getOrEstablishSession(
        sessionKey: SessionKey, identity: OwnIdentity
    ) async throws -> SessionResult {
        if let existing = state.withLock({ $0.sessions[sessionKey] }) {
            return SessionResult(
                session: existing.session, ad: existing.associatedData, kexInfo: nil
            )
        }
        return try await establishSession(
            sessionKey: sessionKey, identity: identity
        )
    }

    private func establishSession(
        sessionKey: SessionKey, identity: OwnIdentity
    ) async throws -> SessionResult {
        let bundle = try await fetchBundle(
            from: sessionKey.jid, deviceID: sessionKey.deviceID
        )
        let validator = state.withLock { $0.identityKeyValidator }
        if let validator {
            try await validator(
                sessionKey.jid, sessionKey.deviceID, bundle.identityKey
            )
        }
        let selectedPreKey = bundle.preKeys.randomElement()
        let peerBundle = OMEMOX3DHPeerBundle(
            identityKey: bundle.identityKey,
            signedPreKey: bundle.signedPreKey,
            signedPreKeySignature: bundle.signedPreKeySignature,
            oneTimePreKey: selectedPreKey?.publicKey
        )
        let x3dhResult = try OMEMOX3DH.initiatorKeyAgreement(
            identityKeyPair: identity.identityKeyPair,
            peerBundle: peerBundle
        )
        let session = try OMEMODoubleRatchetSession(
            asInitiatorWithSharedSecret: x3dhResult.sharedSecret,
            peerSignedPreKey: bundle.signedPreKey
        )
        let context = state.withLock {
            $0.sessions[sessionKey] = SessionEntry(
                session: session, associatedData: x3dhResult.associatedData
            )
            return $0.context
        }
        context?.emitEvent(.omemoSessionEstablished(
            jid: sessionKey.jid, deviceID: sessionKey.deviceID,
            identityKey: bundle.identityKey
        ))
        return SessionResult(
            session: session,
            ad: x3dhResult.associatedData,
            kexInfo: InitiatorKexInfo(
                ephemeralPublicKey: x3dhResult.ephemeralPublicKey,
                peerSignedPreKeyID: bundle.signedPreKeyID,
                peerPreKeyID: selectedPreKey?.id
            )
        )
    }

    // MARK: - SCE Envelope (XEP-0420)

    func buildSCEEnvelope(body: String) -> [UInt8] {
        var content = XMLElement(
            name: "content", namespace: XMPPNamespaces.sce
        )
        var payload = XMLElement(name: "payload")
        var bodyEl = XMLElement(
            name: "body", namespace: "jabber:client"
        )
        bodyEl.addText(body)
        payload.addChild(bodyEl)
        content.addChild(payload)
        var rpad = XMLElement(name: "rpad")
        rpad.addText(randomPadding())
        content.addChild(rpad)
        return Array(content.xmlString.utf8)
    }

    func parseSCEBody(_ data: [UInt8]) -> String? {
        let xml = String(decoding: data, as: UTF8.self)
        // Extract body text from known SCE envelope structure.
        // The envelope is produced by buildSCEEnvelope, so the format
        // is deterministic: <content><payload><body>TEXT</body>...
        guard let bodyStart = xml.range(of: "<body"),
              let contentStart = xml.range(
                  of: ">", range: bodyStart.upperBound ..< xml.endIndex
              ),
              let bodyEnd = xml.range(
                  of: "</body>",
                  range: contentStart.upperBound ..< xml.endIndex
              )
        else {
            // Not an SCE envelope — return raw text
            return xml.isEmpty ? nil : xml
        }
        let raw = xml[contentStart.upperBound ..< bodyEnd.lowerBound]
        return unescapeXMLEntities(String(raw))
    }

    private func unescapeXMLEntities(_ text: String) -> String {
        guard text.firstIndex(of: "&" as Character) != nil else {
            return text
        }
        var result: [Character] = []
        result.reserveCapacity(text.count)
        var rest = text[...]
        while let idx = rest.firstIndex(of: "&" as Character) {
            result.append(contentsOf: rest[rest.startIndex ..< idx])
            let tail = rest[idx...]
            let (replacement, advance) = matchEntity(tail)
            result.append(replacement)
            rest = rest[rest.index(idx, offsetBy: advance)...]
        }
        result.append(contentsOf: rest)
        return String(result)
    }

    private func matchEntity(
        _ tail: Substring
    ) -> (Character, Int) {
        if tail.hasPrefix("&amp;") { return ("&", 5) }
        if tail.hasPrefix("&lt;") { return ("<", 4) }
        if tail.hasPrefix("&gt;") { return (">", 4) }
        if tail.hasPrefix("&apos;") { return ("'", 6) }
        if tail.hasPrefix("&quot;") { return ("\"", 6) }
        return ("&", 1)
    }

    // MARK: - XML Parsing

    func parseDeviceList(
        _ element: XMLElement
    ) -> [UInt32] {
        element.children(named: "device").compactMap { device in
            guard let idStr = device.attribute("id"),
                  let id = UInt32(idStr)
            else { return nil }
            return id
        }
    }

    func parseBundleElement(
        _ element: XMLElement, deviceID: UInt32
    ) -> OMEMOBundle? {
        guard let spkEl = element.child(named: "signedPreKeyPublic"),
              let spkText = spkEl.textContent,
              let spkBytes = Base64.decode(spkText),
              let spkIDStr = spkEl.attribute("signedPreKeyId"),
              let spkID = UInt32(spkIDStr)
        else { return nil }
        guard let sigEl = element.child(named: "signedPreKeySignature"),
              let sigText = sigEl.textContent,
              let sigBytes = Base64.decode(sigText)
        else { return nil }
        guard let ikEl = element.child(named: "identityKey"),
              let ikText = ikEl.textContent,
              let ikBytes = Base64.decode(ikText)
        else { return nil }
        guard let prekeysEl = element.child(named: "prekeys")
        else { return nil }
        let preKeys = parsePreKeys(prekeysEl)
        return OMEMOBundle(
            deviceID: OMEMODeviceID(value: deviceID),
            identityKey: ikBytes,
            signedPreKeyID: spkID,
            signedPreKey: spkBytes,
            signedPreKeySignature: sigBytes,
            preKeys: preKeys
        )
    }

    private func parsePreKeys(
        _ element: XMLElement
    ) -> [OMEMOBundle.PreKeyPublic] {
        element.children(named: "preKeyPublic").compactMap { pk in
            guard let idStr = pk.attribute("preKeyId"),
                  let id = UInt32(idStr),
                  let text = pk.textContent,
                  let bytes = Base64.decode(text)
            else { return nil }
            return OMEMOBundle.PreKeyPublic(id: id, publicKey: bytes)
        }
    }

    private func parseHeader(
        _ encrypted: XMLElement
    ) throws -> ParsedHeader {
        guard let header = encrypted.child(named: "header"),
              let sidStr = header.attribute("sid"),
              let sid = UInt32(sidStr)
        else {
            throw OMEMOModuleError.invalidHeader
        }
        return ParsedHeader(element: header, sid: sid)
    }

    private func findKeyElement(
        _ header: XMLElement, rid: UInt32
    ) -> XMLElement? {
        let ridStr = "\(rid)"
        return header.children(named: "key").first {
            $0.attribute("rid") == ridStr
        }
    }

    // MARK: - XML Building

    private func buildDeviceListElement(
        _ devices: [UInt32]
    ) -> XMLElement {
        var list = XMLElement(
            name: "list", namespace: XMPPNamespaces.omemo
        )
        for id in devices {
            let device = XMLElement(
                name: "device", attributes: ["id": "\(id)"]
            )
            list.addChild(device)
        }
        return list
    }

    func buildBundleElement(
        _ bundle: OMEMOBundle
    ) -> XMLElement {
        var bundleEl = XMLElement(
            name: "bundle", namespace: XMPPNamespaces.omemo
        )
        var spk = XMLElement(
            name: "signedPreKeyPublic",
            attributes: ["signedPreKeyId": "\(bundle.signedPreKeyID)"]
        )
        spk.addText(Base64.encode(bundle.signedPreKey))
        bundleEl.addChild(spk)
        var sig = XMLElement(name: "signedPreKeySignature")
        sig.addText(Base64.encode(bundle.signedPreKeySignature))
        bundleEl.addChild(sig)
        var ik = XMLElement(name: "identityKey")
        ik.addText(Base64.encode(bundle.identityKey))
        bundleEl.addChild(ik)
        var prekeys = XMLElement(name: "prekeys")
        for pk in bundle.preKeys {
            var pkEl = XMLElement(
                name: "preKeyPublic",
                attributes: ["preKeyId": "\(pk.id)"]
            )
            pkEl.addText(Base64.encode(pk.publicKey))
            prekeys.addChild(pkEl)
        }
        bundleEl.addChild(prekeys)
        return bundleEl
    }

    func buildEncryptedElement(
        keys: [XMLElement], payload: String,
        senderDeviceID: UInt32
    ) -> XMLElement {
        var encrypted = XMLElement(
            name: "encrypted", namespace: XMPPNamespaces.omemo
        )
        var header = XMLElement(
            name: "header",
            attributes: ["sid": "\(senderDeviceID)"]
        )
        for key in keys {
            header.addChild(key)
        }
        encrypted.addChild(header)
        var payloadEl = XMLElement(name: "payload")
        payloadEl.addText(payload)
        encrypted.addChild(payloadEl)
        return encrypted
    }

    private func buildKeyElement(
        deviceID: UInt32, data: [UInt8], isKex: Bool
    ) -> XMLElement {
        var attrs = ["rid": "\(deviceID)"]
        if isKex { attrs["kex"] = "true" }
        var key = XMLElement(name: "key", attributes: attrs)
        key.addText(Base64.encode(data))
        return key
    }

    // MARK: - Key Wire Format

    private func serializeKeyExchange(
        ratchetMessage: OMEMORatchetMessage,
        identity: OwnIdentity, kexInfo: InitiatorKexInfo
    ) -> [UInt8] {
        var result: [UInt8] = []
        appendBigEndian(kexInfo.peerSignedPreKeyID, to: &result)
        let pkID = kexInfo.peerPreKeyID ?? 0xFFFF_FFFF
        appendBigEndian(pkID, to: &result)
        result.append(
            contentsOf: identity.identityKeyPair.publicKeyBytes
        )
        result.append(contentsOf: kexInfo.ephemeralPublicKey)
        result.append(
            contentsOf: serializeRatchetMessage(ratchetMessage)
        )
        return result
    }

    func serializeRatchetMessage(
        _ message: OMEMORatchetMessage
    ) -> [UInt8] {
        var result = message.header.encode()
        result.append(contentsOf: message.payload.ciphertext)
        result.append(contentsOf: message.payload.truncatedHMAC)
        return result
    }

    private func deserializeKeyExchange(
        _ data: [UInt8]
    ) throws -> KeyExchangeData {
        // 4 (spkID) + 4 (pkID) + 32 (identity) + 32 (ephemeral) = 72
        guard data.count >= 72 + 40 + 16 else {
            throw OMEMOModuleError.invalidKeyData
        }
        let spkID = readBigEndian(data, offset: 0)
        let pkID = readBigEndian(data, offset: 4)
        let identityKey = Array(data[8 ..< 40])
        let ephemeralKey = Array(data[40 ..< 72])
        let ratchetMessage = try deserializeRatchetMessage(
            Array(data[72...])
        )
        return KeyExchangeData(
            signedPreKeyID: spkID,
            preKeyID: pkID == 0xFFFF_FFFF ? nil : pkID,
            identityKey: identityKey,
            ephemeralKey: ephemeralKey,
            ratchetMessage: ratchetMessage
        )
    }

    func deserializeRatchetMessage(
        _ data: [UInt8]
    ) throws -> OMEMORatchetMessage {
        // 32 (DH key) + 4 (prev count) + 4 (msg number) + N (ciphertext) + 16 (HMAC)
        guard data.count >= 40 + 16 else {
            throw OMEMOModuleError.invalidKeyData
        }
        let dhPublicKey = Array(data[0 ..< 32])
        let prevCount = readLittleEndian(data, offset: 32)
        let msgNumber = readLittleEndian(data, offset: 36)
        let ciphertext = Array(data[40 ..< data.count - 16])
        let hmac = Array(data[data.count - 16 ..< data.count])
        let header = OMEMORatchetHeader(
            dhPublicKey: dhPublicKey,
            previousChainCount: prevCount,
            messageNumber: msgNumber
        )
        let payload = OMEMOEncryptedPayload(
            ciphertext: ciphertext, truncatedHMAC: hmac
        )
        return OMEMORatchetMessage(header: header, payload: payload)
    }

    // MARK: - Publish Options

    private func pepPublishOptions(
        maxItems: Int? = nil
    ) -> [DataFormField] {
        var fields = [
            DataFormField.pubsubPublishOptionsHeader,
            DataFormField(variable: "pubsub#persist_items", values: ["true"]),
            DataFormField(variable: "pubsub#access_model", values: ["open"])
        ]
        if let maxItems {
            fields.append(
                DataFormField(variable: "pubsub#max_items", values: ["\(maxItems)"])
            )
        }
        return fields
    }

    // MARK: - Helpers

    private func bundleNodeName(
        _ deviceID: UInt32
    ) -> String {
        "\(Self.bundleNodePrefix)\(deviceID)"
    }

    private func randomBytes(_ count: Int) -> [UInt8] {
        (0 ..< count).map { _ in UInt8.random(in: 0 ... 255) }
    }

    private func randomPadding() -> String {
        let length = Int.random(in: 1 ... 200)
        let bytes = (0 ..< length).map { _ in
            UInt8.random(in: 0x20 ... 0x7E)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func appendBigEndian(
        _ value: UInt32, to buffer: inout [UInt8]
    ) {
        buffer.append(UInt8(value >> 24 & 0xFF))
        buffer.append(UInt8(value >> 16 & 0xFF))
        buffer.append(UInt8(value >> 8 & 0xFF))
        buffer.append(UInt8(value & 0xFF))
    }

    func readBigEndian(
        _ data: [UInt8], offset: Int
    ) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    func readLittleEndian(
        _ data: [UInt8], offset: Int
    ) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}

// MARK: - Public Types

public extension OMEMOModule {
    /// Elements to attach to an outgoing message for OMEMO encryption.
    struct EncryptedMessageElements: Sendable {
        /// `<encrypted xmlns='urn:xmpp:omemo:2'>` with header and payload.
        public let encrypted: XMLElement
        /// `<encryption xmlns='urn:xmpp:eme:0'>` (XEP-0380).
        public let encryption: XMLElement
        /// Fallback body for non-OMEMO clients.
        public let fallbackBody: String
        /// Recipient devices that were skipped because no bundle could be
        /// fetched (`item-not-found` / `bundleNotFound`). Empty in the common
        /// path; non-empty signals partial recipient coverage. Defaulted on
        /// the explicit init so existing call sites keep working.
        public let droppedRecipients: [DroppedOMEMORecipient]

        public init(
            encrypted: XMLElement,
            encryption: XMLElement,
            fallbackBody: String,
            droppedRecipients: [DroppedOMEMORecipient] = []
        ) {
            self.encrypted = encrypted
            self.encryption = encryption
            self.fallbackBody = fallbackBody
            self.droppedRecipients = droppedRecipients
        }
    }

    /// Serializable identity data for persistent storage.
    struct OMEMOIdentityData: Sendable {
        public let deviceID: UInt32
        /// Ed25519 seed (32 bytes).
        public let identityKeyRaw: [UInt8]
        public let signedPreKeyID: UInt32
        /// X25519 private key raw (32 bytes).
        public let signedPreKeyRaw: [UInt8]
        /// Ed25519 signature over the signed pre-key (64 bytes).
        public let signedPreKeySignature: [UInt8]
        public let preKeys: [PreKeyData]

        public struct PreKeyData: Sendable {
            public let keyID: UInt32
            /// X25519 private key raw (32 bytes).
            public let keyRaw: [UInt8]

            public init(keyID: UInt32, keyRaw: [UInt8]) {
                self.keyID = keyID
                self.keyRaw = keyRaw
            }
        }

        public init(
            deviceID: UInt32,
            identityKeyRaw: [UInt8],
            signedPreKeyID: UInt32,
            signedPreKeyRaw: [UInt8],
            signedPreKeySignature: [UInt8],
            preKeys: [PreKeyData]
        ) {
            self.deviceID = deviceID
            self.identityKeyRaw = identityKeyRaw
            self.signedPreKeyID = signedPreKeyID
            self.signedPreKeyRaw = signedPreKeyRaw
            self.signedPreKeySignature = signedPreKeySignature
            self.preKeys = preKeys
        }
    }

    /// Serializable session entry for persistent storage.
    struct StoredSessionEntry: Sendable {
        public let jid: BareJID
        public let deviceID: UInt32
        /// Serialized `OMEMODoubleRatchetSession` bytes.
        public let sessionData: [UInt8]
        /// X3DH associated data (64 bytes).
        public let associatedData: [UInt8]

        public init(jid: BareJID, deviceID: UInt32, sessionData: [UInt8], associatedData: [UInt8]) {
            self.jid = jid
            self.deviceID = deviceID
            self.sessionData = sessionData
            self.associatedData = associatedData
        }
    }
}

// MARK: - Identity Provider Protocol

/// Read-only access to an OMEMO identity source. Lets `OMEMOService` consume
/// the surfaces it needs from `OMEMOModule` (`ownIdentityData`,
/// `consumedPreKeyIDs()`) without holding a concrete module reference, so the
/// connect-time first-time-persistence path can be exercised under unit tests.
package protocol OMEMOIdentityProviding: Sendable {
    var ownIdentityData: OMEMOModule.OMEMOIdentityData? { get }
    func consumedPreKeyIDs() -> Set<UInt32>
}

extension OMEMOModule: OMEMOIdentityProviding {}

// MARK: - Previously-Seen Device IDs Provider

/// Read/write access to a per-account "device IDs we've seen on a prior
/// connect" set. `OMEMOService` (which outlives reconnects) stores the set
/// and conforms; `OMEMOModule.pruneStaleBundles` reads it to gate
/// auto-retract on prior observation, then writes the post-trim list back.
///
/// `accountID` is an opaque String — DuckoXMPP cannot import Foundation
/// (because `XMLElement` would clash with `NSXMLElement`), so the token is
/// passed through as a plain String. In production it is the consumer's
/// `UUID.uuidString`; tests can use any unique string.
package protocol PreviouslySeenDeviceIDsProviding: Sendable {
    func previouslySeenDeviceIDs(accountID: String) async -> Set<UInt32>
    func updatePreviouslySeenDeviceIDs(_ ids: Set<UInt32>, accountID: String) async
}

// MARK: - Errors

/// Errors from OMEMO protocol operations (distinct from crypto errors).
enum OMEMOModuleError: Error {
    case notSetUp
    case bundleNotFound
    case noSession
    case notForThisDevice
    case invalidKeyData
    case invalidHeader
    case invalidPayload
    /// Every recipient device listed returned `item-not-found` (or equivalent)
    /// for its bundle. The message was not sent.
    case noUsableRecipientDevices
}

// MARK: - Private Types

private struct SessionKey: Hashable {
    let jid: BareJID
    let deviceID: UInt32
}

private struct OwnIdentity {
    let deviceID: OMEMODeviceID
    let identityKeyPair: OMEMOIdentityKeyPair
    let signedPreKey: OMEMOSignedPreKey
    let preKeys: [OMEMOPreKey]
    let connectedJID: FullJID
}

private struct SessionResult {
    let session: OMEMODoubleRatchetSession
    let ad: [UInt8]
    /// Key exchange info for new sessions (nil for existing).
    let kexInfo: InitiatorKexInfo?
}

private struct InitiatorKexInfo {
    let ephemeralPublicKey: [UInt8]
    let peerSignedPreKeyID: UInt32
    let peerPreKeyID: UInt32?
}

private struct ParsedHeader {
    let element: XMLElement
    let sid: UInt32
}

private struct DecryptionResult {
    let body: String?
    let senderDeviceID: UInt32
}

private struct KeyExchangeData {
    let signedPreKeyID: UInt32
    let preKeyID: UInt32?
    let identityKey: [UInt8]
    let ephemeralKey: [UInt8]
    let ratchetMessage: OMEMORatchetMessage
}
