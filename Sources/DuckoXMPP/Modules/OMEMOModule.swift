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
        /// Provider of the per-account seen-device classification cache used
        /// by `pruneStaleBundles` to gate auto-retract on a two-stale
        /// healthy-observation lineage. Stored on the service rather than the
        /// module so the cache survives reconnects (modules are rebuilt per
        /// reconnect; the service is held by `AppEnvironment` and outlives
        /// them). `accountID` is an opaque String (the service's
        /// `UUID.uuidString` in production) so this file does not need to
        /// import Foundation; `accountJID` is the wire-keyed JID string used
        /// by the persistence layer (`OMEMOStore` rows are keyed by JID, not
        /// by account UUID).
        var seenDeviceClassificationProvider: (any SeenDeviceClassificationProviding)?
        var seenDeviceClassificationAccountID: String?
        var emergencyRetractGuard: (any EmergencyRetractGuarding)?
        var emergencyRetractConfirmation: EmergencyRetractConfirmation?
        var orphanDeviceRecordPurger: (any OrphanDeviceRecordPurging)?
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
            $0.seenDeviceClassificationProvider = nil
            $0.seenDeviceClassificationAccountID = nil
            $0.emergencyRetractGuard = nil
            $0.emergencyRetractConfirmation = nil
            $0.orphanDeviceRecordPurger = nil
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

    /// Wires the seen-device classification provider used by
    /// ``pruneStaleBundles(ownDeviceID:ownDeviceList:)`` to gate auto-retract
    /// on a two-stale healthy-observation lineage. The provider is shared
    /// per-account by `OMEMOService`, which holds the cache across reconnects.
    ///
    /// DuckoXMPP carries only the opaque `accountID` token (a String the
    /// service treats as its `UUID.uuidString`). The persistence-side
    /// JID lookup happens on the service side because `OMEMOStore` rows
    /// are keyed by JID, not by accountID.
    package func configureSeenDeviceClassificationProvider(
        _ provider: any SeenDeviceClassificationProviding,
        accountID: String
    ) {
        state.withLock {
            $0.seenDeviceClassificationProvider = provider
            $0.seenDeviceClassificationAccountID = accountID
        }
    }

    /// Wires the emergency-retract confirmation closure and reentrancy guard
    /// used by ``pruneStaleBundles(ownDeviceID:ownDeviceList:)`` to recover
    /// from over-cap devicelist accumulation. Both live on `OMEMOService` —
    /// the closure surfaces to UI; the in-flight guard must survive reconnects
    /// mid-retract (modules are rebuilt per reconnect, the service is not).
    /// `orphanPurger` deletes trust/session rows for retracted own-deviceIDs.
    package func configureEmergencyRetract(
        confirmation: EmergencyRetractConfirmation?,
        guard inFlightGuard: any EmergencyRetractGuarding,
        orphanPurger: any OrphanDeviceRecordPurging
    ) {
        state.withLock {
            $0.emergencyRetractConfirmation = confirmation
            $0.emergencyRetractGuard = inFlightGuard
            $0.orphanDeviceRecordPurger = orphanPurger
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

    /// Maximum number of concurrent per-recipient bundle fetches during
    /// encrypt. Without bounding fan-out, a peer with thousands of devices
    /// would spawn N concurrent IQ fetches per send and saturate SM ack
    /// windows (observed at 950+ devices). The cap doesn't restrict total
    /// recipients, only in-flight fetches; chunked iteration completes
    /// every device. Value chosen empirically: 64 is small enough that
    /// SM windows don't fill, large enough to amortize TLS handshakes on
    /// realistic device counts.
    private static let encryptConcurrencyCap = 64

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
        //
        // Chunk via `stride` + per-chunk `withThrowingTaskGroup`, mirroring
        // the bounded-parallel idiom already used in `classifyBundleProbes`.
        // Each chunk completes before the next starts, so at most
        // `encryptConcurrencyCap` IQ fetches are in flight at a time.
        enum Outcome: Sendable {
            case encrypted(EncryptionResult)
            case dropped(DroppedOMEMORecipient)
        }
        var batch = EncryptionBatch(results: [], dropped: [])
        batch.results.reserveCapacity(devices.count)
        for chunkStart in stride(from: 0, to: devices.count, by: Self.encryptConcurrencyCap) {
            let chunkEnd = min(chunkStart + Self.encryptConcurrencyCap, devices.count)
            let chunk = Array(devices[chunkStart ..< chunkEnd])
            try await withThrowingTaskGroup(of: Outcome.self) { group in
                for device in chunk {
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
                for try await outcome in group {
                    switch outcome {
                    case let .encrypted(result):
                        batch.results.append(result)
                    case let .dropped(drop):
                        batch.dropped.append(drop)
                    }
                }
            }
        }
        return batch
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

    /// Maximum number of peer deviceIDs to probe in a single prune cycle.
    /// A malicious or compromised PEP server can return an arbitrarily large
    /// own-device list; without a cap, every reconnect would issue thousands
    /// of bundle-probe IQs, blocking connect and saturating logs/network.
    /// 64 is generous for any realistic legitimate user (own devices on one
    /// account) and small enough to bound the worst case.
    private static let pruneProbeCap = 64

    /// Threshold of consecutive `.stale` observations after a prior `.healthy`
    /// before auto-retract fires. The "two strikes after a confirmed-healthy
    /// observation" gate defends against a malicious own-server answering
    /// `item-not-found` for a real sibling's bundle on a single reconnect to
    /// coerce a retract: one stale alone never retracts, only a confirmed
    /// streak does.
    private static let staleRetractStreakThreshold = 2

    /// Probes each peer device's bundle on the published own-device list,
    /// classifies the response, and auto-retracts orphan bundle nodes when
    /// the per-device classification history (kept across reconnects on
    /// `OMEMOService`) shows a healthy → stale → stale lineage. First
    /// observation is always warn-only; an `unseen → stale → stale`
    /// trajectory without a prior `.healthy` never retracts.
    ///
    /// On an over-cap list (`peerDeviceIDs.count > pruneProbeCap`) the prune
    /// invokes the optional emergency-retract closure on the service. If the
    /// closure returns `true`, the path publishes a singleton devicelist
    /// first (mirroring `retractAndRePublish`'s rollback-safe ordering),
    /// then best-effort retracts every non-own bundle node, purges orphan
    /// trust/session rows, and resets the cache to a singleton baseline.
    ///
    /// - Parameters:
    ///   - ownDeviceID: This client's device ID; never probed/retracted.
    ///   - ownDeviceList: The current device-list contents at PEP.
    /// - Returns: The (possibly trimmed) device list.
    /// - Throws: Only when the post-pruning `publishDeviceList(_:)` re-publish
    ///   fails. Per-device probe failures are swallowed (logged at
    ///   `.warning`) so a transient PEP error never aborts the connect chain.
    /// Bundle of per-account slots resolved from `state` at the top of
    /// `pruneStaleBundles`. Carrying them in one struct keeps the
    /// extracted helper functions under the function-parameter-count cap.
    private struct PruneContext {
        let provider: (any SeenDeviceClassificationProviding)?
        let accountID: String?
        let retractGuard: (any EmergencyRetractGuarding)?
        let retractConfirmation: EmergencyRetractConfirmation?
        let orphanPurger: (any OrphanDeviceRecordPurging)?
    }

    private func pruneStaleBundles(
        ownDeviceID: UInt32, ownDeviceList: [UInt32]
    ) async throws -> [UInt32] {
        let peerDeviceIDs = ownDeviceList.filter { $0 != ownDeviceID }
        let context = state.withLock { state in
            PruneContext(
                provider: state.seenDeviceClassificationProvider,
                accountID: state.seenDeviceClassificationAccountID,
                retractGuard: state.emergencyRetractGuard,
                retractConfirmation: state.emergencyRetractConfirmation,
                orphanPurger: state.orphanDeviceRecordPurger
            )
        }

        // Empty peer-list path: drop any leftover sibling records the cache
        // still carries so the next list-regrowth sees the new IDs as
        // truly unseen. The old "anchor to whatever PEP currently lists"
        // pattern is replaced — membership is now decoupled from
        // classification.
        guard !peerDeviceIDs.isEmpty else {
            if let provider = context.provider, let accountID = context.accountID {
                await provider.clearSeenDevicesAbsent(from: Set([ownDeviceID]), accountID: accountID)
            }
            return ownDeviceList
        }

        if peerDeviceIDs.count > Self.pruneProbeCap {
            return try await handleOverCapDeviceList(
                ownDeviceID: ownDeviceID, ownDeviceList: ownDeviceList,
                peerDeviceCount: peerDeviceIDs.count, context: context
            )
        }

        let classifications = await classifyBundleProbes(deviceIDs: peerDeviceIDs)
        let previousRecords = await loadPreviousSeenRecords(context: context)
        let (updatedRecords, retractIDs) = computeProbeOutcome(
            classifications: classifications, previousRecords: previousRecords
        )

        if !retractIDs.isEmpty {
            return try await retractAndRePublish(
                retractIDs: retractIDs,
                ownDeviceList: ownDeviceList,
                updatedRecords: updatedRecords,
                provider: context.provider,
                accountID: context.accountID
            )
        }

        if let provider = context.provider, let accountID = context.accountID {
            await provider.mergeSeenDevices(updatedRecords, accountID: accountID)
            // Drop records for IDs that vanished from PEP (legitimate sibling
            // retraction) so a peer's "old healthy survives after
            // disappearance" attack can't bypass the gate on the next regrow.
            await provider.clearSeenDevicesAbsent(from: Set(ownDeviceList), accountID: accountID)
        }
        return ownDeviceList
    }

    /// Loads the previous classification cache once per prune cycle. Falls
    /// back to an empty map when no provider is wired.
    private func loadPreviousSeenRecords(context: PruneContext) async -> [UInt32: SeenDeviceRecord] {
        guard let provider = context.provider, let accountID = context.accountID else { return [:] }
        return await provider.loadSeenDevices(accountID: accountID)
    }

    /// Folds the per-device classification results into updated records
    /// plus the retract list. Pulled out so the parent function stays
    /// under the function-body-length lint cap.
    private func computeProbeOutcome(
        classifications: [(id: UInt32, classification: BundleClassification)],
        previousRecords: [UInt32: SeenDeviceRecord]
    ) -> (updatedRecords: [UInt32: SeenDeviceRecord], retractIDs: [UInt32]) {
        var updatedRecords: [UInt32: SeenDeviceRecord] = [:]
        var retractIDs: [UInt32] = []
        for (deviceID, classification) in classifications.map({ ($0.id, $0.classification) }) {
            let outcome = nextSeenDeviceRecord(
                deviceID: deviceID,
                classification: classification,
                previous: previousRecords[deviceID]
            )
            updatedRecords[deviceID] = outcome.record
            if outcome.shouldRetract {
                retractIDs.append(deviceID)
            }
        }
        return (updatedRecords, retractIDs)
    }

    /// Resource-exhaustion guard: an over-cap list is adversary-provided
    /// and untrustworthy. Preserve the cache state and let the emergency-
    /// retract closure (when configured) prompt the user to recover.
    private func handleOverCapDeviceList(
        ownDeviceID: UInt32, ownDeviceList: [UInt32],
        peerDeviceCount: Int, context: PruneContext
    ) async throws -> [UInt32] {
        log.warning("OMEMO device list has \(peerDeviceCount) peer devices, exceeding probe cap; skipping prune")
        guard let accountID = context.accountID,
              let retractGuard = context.retractGuard,
              let retractConfirmation = context.retractConfirmation
        else { return ownDeviceList }
        let claimed = await retractGuard.tryClaimInFlight(accountID: accountID)
        guard claimed else { return ownDeviceList }
        // `defer` cannot await; release after the publish/retract/cleanup
        // path completes so a second prune during this window sees the
        // in-flight flag and bails.
        do {
            let confirmed = await retractConfirmation(peerDeviceCount, ownDeviceID)
            guard confirmed else {
                await retractGuard.releaseInFlight(accountID: accountID)
                return ownDeviceList
            }
            let result = try await performEmergencyRetract(
                ownDeviceID: ownDeviceID, ownDeviceList: ownDeviceList,
                provider: context.provider, accountID: accountID,
                orphanPurger: context.orphanPurger
            )
            await retractGuard.releaseInFlight(accountID: accountID)
            return result
        } catch {
            await retractGuard.releaseInFlight(accountID: accountID)
            throw error
        }
    }

    /// Result of folding one bundle-probe classification into the
    /// per-device seen-device record: the updated record to persist and a
    /// flag indicating whether the gate fires (retract this device).
    private struct SeenDeviceProgress {
        let record: SeenDeviceRecord
        let shouldRetract: Bool
    }

    /// Folds a single classification result into the per-device seen-device
    /// record. Extracted from `pruneStaleBundles` so the gate's transition
    /// logic stays under the cyclomatic-complexity lint cap and is easier to
    /// reason about in isolation.
    private func nextSeenDeviceRecord(
        deviceID: UInt32,
        classification: BundleClassification,
        previous: SeenDeviceRecord?
    ) -> SeenDeviceProgress {
        switch classification {
        case .healthy:
            return SeenDeviceProgress(
                record: SeenDeviceRecord(
                    deviceID: deviceID, lastClassification: .healthy,
                    staleStreak: 0, hasObservedHealthy: true
                ),
                shouldRetract: false
            )
        case .transient:
            // Preserve the previous record verbatim to avoid penalizing
            // intermittent network failures. First observation as transient
            // still records the lineage so a future healthy can flip
            // `hasObservedHealthy`.
            if let previous {
                return SeenDeviceProgress(record: previous, shouldRetract: false)
            }
            log.info("OMEMO stale bundle first observation classified as transient")
            log.debug("OMEMO stale bundle device \(deviceID) classified as transient (no prior record)")
            return SeenDeviceProgress(
                record: SeenDeviceRecord(
                    deviceID: deviceID, lastClassification: .transient,
                    staleStreak: 0, hasObservedHealthy: false
                ),
                shouldRetract: false
            )
        case .stale:
            return staleSeenDeviceProgress(deviceID: deviceID, previous: previous)
        }
    }

    /// Stale-branch of `nextSeenDeviceRecord`: increments the streak,
    /// preserves the `hasObservedHealthy` flag, and decides whether the
    /// two-stale gate fires. Split out so the parent function stays under
    /// the cyclomatic-complexity cap.
    private func staleSeenDeviceProgress(
        deviceID: UInt32,
        previous: SeenDeviceRecord?
    ) -> SeenDeviceProgress {
        let staleStreak = (previous?.staleStreak ?? 0) + 1
        let hasObservedHealthy = previous?.hasObservedHealthy ?? false
        let record = SeenDeviceRecord(
            deviceID: deviceID, lastClassification: .stale,
            staleStreak: staleStreak, hasObservedHealthy: hasObservedHealthy
        )
        let shouldRetract = hasObservedHealthy && staleStreak >= Self.staleRetractStreakThreshold
        logStaleObservation(
            deviceID: deviceID, staleStreak: staleStreak,
            hasObservedHealthy: hasObservedHealthy,
            previous: previous, willRetract: shouldRetract
        )
        return SeenDeviceProgress(record: record, shouldRetract: shouldRetract)
    }

    /// Emits the operator-facing log line for a single stale observation.
    /// Privacy policy: counts and outcomes go at `.info`/`.warning`;
    /// the device ID is logged at `.debug` only.
    private func logStaleObservation(
        deviceID: UInt32,
        staleStreak: Int,
        hasObservedHealthy: Bool,
        previous: SeenDeviceRecord?,
        willRetract: Bool
    ) {
        if willRetract {
            log.warning("OMEMO auto-retracting confirmed-stale bundle (streak \(staleStreak))")
            log.debug("OMEMO auto-retracting confirmed-stale bundle device \(deviceID) staleStreak=\(staleStreak)")
        } else if hasObservedHealthy {
            log.info("OMEMO stale bundle confirmed once; will auto-retract on next reconnect if still missing")
            log.debug("OMEMO stale bundle device \(deviceID) staleStreak=\(staleStreak)")
        } else if previous == nil {
            log.info("OMEMO stale bundle first observation; no prior healthy, not auto-retracting")
            log.debug("OMEMO stale bundle first observation device \(deviceID)")
        } else {
            log.info("OMEMO stale bundle observed \(staleStreak) times without prior healthy; not auto-retracting")
            log.debug("OMEMO stale bundle device \(deviceID) staleStreak=\(staleStreak) no prior healthy")
        }
    }

    /// Publishes a singleton devicelist (`[ownDeviceID]`) FIRST, then
    /// best-effort retracts each non-own bundle node, purges orphan
    /// trust/session rows for the retracted own-deviceIDs, and installs a
    /// clean singleton baseline in the seen-device cache. Mirrors
    /// `retractAndRePublish`'s publish-first ordering: if the publish fails
    /// the subsequent retracts are not attempted and PEP is unchanged.
    private func performEmergencyRetract(
        ownDeviceID: UInt32,
        ownDeviceList: [UInt32],
        provider: (any SeenDeviceClassificationProviding)?,
        accountID: String,
        orphanPurger: (any OrphanDeviceRecordPurging)?
    ) async throws -> [UInt32] {
        let trimmedList = [ownDeviceID]
        try await publishDeviceList(trimmedList)

        let retractIDs = ownDeviceList.filter { $0 != ownDeviceID }
        for id in retractIDs {
            do {
                try await pepModule.retractItem(
                    node: bundleNodeName(id), itemID: Self.bundleItemID
                )
            } catch let stanzaError as XMPPStanzaError {
                log.warning("OMEMO emergency-retract bundle failed: \(stanzaError.condition.rawValue)")
                log.debug("OMEMO emergency-retract bundle failed for device \(id): \(stanzaError.condition.rawValue)")
            } catch {
                log.warning("OMEMO emergency-retract bundle failed")
                log.debug("OMEMO emergency-retract bundle failed for device \(id): \(error)")
            }
        }

        // Orphan trust/session cleanup is fail-loud: if it fails the user
        // sees the dialog state didn't fully apply. Bookkeeping rows for
        // retracted own-deviceIDs would otherwise be targetable from a
        // restored backup whose local bundles still cache them.
        if let orphanPurger {
            do {
                try await orphanPurger.purgeOrphanDeviceRecords(deviceIDs: retractIDs, accountID: accountID)
            } catch {
                log.warning("OMEMO emergency-retract orphan cleanup failed")
                log.debug("OMEMO emergency-retract orphan cleanup failed: \(error)")
                throw error
            }
        }

        let connectedJID = state.withLock { $0.context?.connectedJID()?.bareJID }
        if let connectedJID {
            state.withLock { $0.deviceLists[connectedJID] = trimmedList }
        }
        if let provider {
            // `replace` (not `merge`) is critical — delta-merge would leave
            // old sibling rows in the cache and re-trigger the gate on the
            // next prune.
            await provider.replaceSeenDevices(
                [ownDeviceID: SeenDeviceRecord(
                    deviceID: ownDeviceID,
                    lastClassification: .healthy,
                    staleStreak: 0,
                    hasObservedHealthy: true
                )],
                accountID: accountID
            )
        }
        log.warning("OMEMO emergency-retract completed: trimmed to singleton, \(retractIDs.count) bundle(s) retracted")
        return trimmedList
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
            log.warning("OMEMO bundle probe failed: \(stanzaError.condition.rawValue)")
            log.debug("OMEMO bundle probe failed for device \(deviceID): \(stanzaError.condition.rawValue)")
            return (id: deviceID, classification: .transient)
        } catch {
            log.warning("OMEMO bundle probe failed")
            log.debug("OMEMO bundle probe failed for device \(deviceID): \(error)")
            return (id: deviceID, classification: .transient)
        }
    }

    /// Re-publishes the trimmed device list FIRST so a subsequent retract
    /// failure leaves PEP no worse off — a future `fetchBundle` on a
    /// still-orphan bundle is harmless because the device list no longer
    /// names it. After re-publish, retracts each orphan bundle, then updates
    /// in-memory cache and merges classification updates.
    private func retractAndRePublish(
        retractIDs: [UInt32],
        ownDeviceList: [UInt32],
        updatedRecords: [UInt32: SeenDeviceRecord],
        provider: (any SeenDeviceClassificationProviding)?,
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
                log.warning("OMEMO bundle retract failed: \(stanzaError.condition.rawValue)")
                log.debug("OMEMO bundle retract failed for device \(id): \(stanzaError.condition.rawValue)")
            } catch {
                log.warning("OMEMO bundle retract failed")
                log.debug("OMEMO bundle retract failed for device \(id): \(error)")
            }
        }
        let connectedJID = state.withLock { $0.context?.connectedJID()?.bareJID }
        if let connectedJID {
            state.withLock { $0.deviceLists[connectedJID] = trimmedList }
        }
        if let provider, let accountID {
            // Drop records for retracted IDs from the updates we're about to
            // persist; they're gone from PEP and we don't want them coming
            // back via merge. `clearSeenDevicesAbsent` then deletes the
            // corresponding cache rows so the next prune sees a clean slate
            // for the IDs that disappeared.
            var survivingUpdates = updatedRecords
            for id in retractIDs {
                survivingUpdates.removeValue(forKey: id)
            }
            await provider.mergeSeenDevices(survivingUpdates, accountID: accountID)
            await provider.clearSeenDevicesAbsent(from: Set(trimmedList), accountID: accountID)
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

// MARK: - Seen Device Classification

/// Probe outcome classification used by ``OMEMOModule/pruneStaleBundles`` to
/// decide whether a peer device's PEP-listed bundle is healthy, missing
/// (`.stale`), or in an ambiguous state we should not act on yet
/// (`.transient`). Promoted to `package` Sendable+Codable so the seen-device
/// classification cache crosses the DuckoXMPP→DuckoCore boundary intact.
package enum BundleClassification: String, Codable {
    case stale
    case healthy
    case transient
}

/// Per-device record carried across reconnects to gate auto-retract on a
/// two-stale healthy-observation lineage. `hasObservedHealthy` is
/// load-bearing: without it, `(.stale, staleStreak: 2)` produced by
/// `unseen → stale → stale` is indistinguishable from the same shape
/// produced by `healthy → stale → stale`, and the gate would retract a
/// sibling whose bundle simply hasn't been published yet.
package struct SeenDeviceRecord: Equatable, Codable {
    package let deviceID: UInt32
    package let lastClassification: BundleClassification
    /// Consecutive `.stale` observations since the last `.healthy` (or since
    /// the lineage began for an `unseen → stale → …` trajectory).
    package let staleStreak: Int
    /// `true` once `.healthy` has been recorded at any prior cycle. The
    /// retract gate fires only when both this is true and the streak reaches
    /// the threshold.
    package let hasObservedHealthy: Bool

    package init(
        deviceID: UInt32,
        lastClassification: BundleClassification,
        staleStreak: Int,
        hasObservedHealthy: Bool
    ) {
        self.deviceID = deviceID
        self.lastClassification = lastClassification
        self.staleStreak = staleStreak
        self.hasObservedHealthy = hasObservedHealthy
    }
}

/// Read/write access to a per-account seen-device classification cache.
/// `OMEMOService` (which outlives reconnects) stores the cache and conforms;
/// `OMEMOModule.pruneStaleBundles` reads it to gate auto-retract on a
/// two-stale healthy-observation lineage, then merges per-device deltas
/// back. All methods are non-throwing — the service-side implementation
/// absorbs `OMEMOStore` errors and falls back to in-memory state rather
/// than aborting the prune pipeline.
///
/// `accountID` is an opaque String — DuckoXMPP cannot import Foundation
/// (because `XMLElement` would clash with `NSXMLElement`), so the token is
/// passed through as a plain String. In production it is the consumer's
/// `UUID.uuidString`; tests can use any unique string.
package protocol SeenDeviceClassificationProviding: Sendable {
    /// Returns the in-memory cache for `accountID`, lazy-loading from the
    /// persistent store on first read per account. Coalesces concurrent
    /// first-load callers via an in-flight `Task` cache.
    func loadSeenDevices(accountID: String) async -> [UInt32: SeenDeviceRecord]

    /// Merges per-device updates into the cache (last-write-wins per
    /// deviceID) and upserts only the delta rows in the store.
    func mergeSeenDevices(_ updates: [UInt32: SeenDeviceRecord], accountID: String) async

    /// Drops rows whose deviceID is not in `currentDeviceIDs`. Used both to
    /// clear sibling records when the published list shrinks and to defend
    /// against a peer's "old healthy survives after disappearance" attack.
    func clearSeenDevicesAbsent(from currentDeviceIDs: Set<UInt32>, accountID: String) async

    /// Replaces the cache wholesale with `records`. Used by the emergency-
    /// retract path to install a clean singleton baseline; delta-merge would
    /// leave old sibling rows in the cache and re-trigger the gate on the
    /// next prune.
    func replaceSeenDevices(_ records: [UInt32: SeenDeviceRecord], accountID: String) async
}

/// Returned from the over-cap emergency-retract confirmation closure;
/// `true` authorizes publish-singleton + bundle retract + orphan cleanup.
package typealias EmergencyRetractConfirmation = @Sendable (_ deviceCount: Int, _ ownDeviceID: UInt32) async -> Bool

/// Service-side reentrancy guard for the emergency-retract path. Lives on
/// `OMEMOService` (not the module) because the module is rebuilt per
/// reconnect and the in-flight flag must survive a mid-retract reconnect —
/// otherwise a second prune entering after the new module is built could
/// re-prompt the user while the publish/retract phase is still running.
package protocol EmergencyRetractGuarding: Sendable {
    /// Atomically checks and sets the in-flight flag for `accountID`.
    /// Returns `true` if the caller claimed it (was not already in flight);
    /// `false` otherwise.
    func tryClaimInFlight(accountID: String) async -> Bool

    /// Clears the in-flight flag for `accountID`. Called via `defer` across
    /// the entire publish/retract path so a second prune sees in-flight=true
    /// for the whole duration, not just the closure await.
    func releaseInFlight(accountID: String) async
}

/// Cleans up trust/session rows for own-deviceIDs that were retracted via
/// the emergency-retract path. Defense-in-depth alongside
/// `encryptKeyForOwnDevices`'s PEP-list intersect: leaving orphan rows in
/// the store would let an offline-restored backup target retracted device
/// IDs whose bundles are still locally cached.
package protocol OrphanDeviceRecordPurging: Sendable {
    func purgeOrphanDeviceRecords(deviceIDs: [UInt32], accountID: String) async throws
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
