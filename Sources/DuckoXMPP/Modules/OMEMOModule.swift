import os

private let log = Logger(subsystem: "de.tobiha.ducko.xmpp", category: "omemo")

/// Implements XEP-0384 OMEMO Encryption and XEP-0380 Explicit Message Encryption.
///
/// Manages device lists, bundles, session establishment (X3DH), and
/// per-message encryption/decryption (Double Ratchet + AES-256-CBC).
/// Uses PEPModule for all PubSub operations.
public final class OMEMOModule: XMPPModule, Sendable {
    // MARK: - State

    private struct State {
        var context: ModuleContext?
        var deviceLists: [BareJID: [UInt32]] = [:]
        var ownIdentity: OwnIdentity?
        var pendingIdentity: OMEMOIdentityData?
        var sessions: [SessionKey: OMEMODoubleRatchetSession] = [:]
        var sessionAD: [SessionKey: [UInt8]] = [:]
        var usedPreKeyIDs: Set<UInt32> = []
    }

    private let state: OSAllocatedUnfairLock<State>
    private let pepModule: PEPModule

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
    }

    public func handleDisconnect() async {
        state.withLock {
            $0.ownIdentity = nil
            $0.deviceLists.removeAll()
            $0.sessions.removeAll()
            $0.sessionAD.removeAll()
            $0.usedPreKeyIDs.removeAll()
        }
    }

    public func handleMessage(_ message: XMPPMessage) throws {
        handleDeviceListNotification(message)
        handleEncryptedMessage(message)
    }

    // MARK: - Public API

    // periphery:ignore - specced feature, wired by DuckoCore in Prompt 20
    /// The current device ID, or `nil` if not yet set up.
    public var ownDeviceID: UInt32? {
        state.withLock { $0.ownIdentity?.deviceID.value }
    }

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
                    state.sessions[key] = session
                    state.sessionAD[key] = entry.associatedData
                }
            }
        }
    }

    /// Exports a single session's state for persistent storage.
    public func exportSession(jid: BareJID, deviceID: UInt32) -> StoredSessionEntry? {
        state.withLock { state in
            let key = SessionKey(jid: jid, deviceID: deviceID)
            guard let session = state.sessions[key],
                  let ad = state.sessionAD[key]
            else { return nil }
            return StoredSessionEntry(
                jid: jid, deviceID: deviceID,
                sessionData: session.serialize(), associatedData: ad
            )
        }
    }

    /// Exports all sessions for persistent storage (e.g., on disconnect).
    public func allSessionEntries() -> [StoredSessionEntry] {
        state.withLock { state in
            state.sessions.compactMap { key, session in
                guard let ad = state.sessionAD[key] else { return nil }
                return StoredSessionEntry(
                    jid: key.jid, deviceID: key.deviceID,
                    sessionData: session.serialize(), associatedData: ad
                )
            }
        }
    }

    /// Fetches device IDs for a JID (from cache or PEP).
    public func fetchDeviceList(
        for jid: BareJID
    ) async throws -> [UInt32] {
        if let cached = state.withLock({ $0.deviceLists[jid] }) {
            return cached
        }
        let devices = try await fetchDeviceListFromPEP(jid)
        state.withLock { $0.deviceLists[jid] = devices }
        return devices
    }

    /// Encrypts a message for the recipient's devices.
    ///
    /// - Parameters:
    ///   - plaintext: Message body to encrypt.
    ///   - recipientJID: The recipient's bare JID.
    ///   - recipientDeviceIDs: Specific device IDs to encrypt for, or `nil` to encrypt for all known devices.
    public func encryptMessage(
        plaintext: String,
        to recipientJID: BareJID,
        recipientDeviceIDs: [UInt32]? = nil
    ) async throws -> EncryptedMessageElements {
        let identity = try requireOwnIdentity()
        let contentKey = randomBytes(32)
        let sceBytes = buildSCEEnvelope(body: plaintext)
        let payload = try encryptPayload(sceBytes, contentKey: contentKey)
        let recipientDevices: [UInt32] = if let recipientDeviceIDs {
            recipientDeviceIDs
        } else {
            try await fetchDeviceList(for: recipientJID)
        }
        var keys: [XMLElement] = []
        for deviceID in recipientDevices {
            let key = try await encryptKeyForDevice(
                contentKey: contentKey, jid: recipientJID,
                deviceID: deviceID, identity: identity
            )
            keys.append(key)
        }
        let ownJID = identity.connectedJID.bareJID
        let ownDevices = try await fetchDeviceList(for: ownJID)
        for deviceID in ownDevices where deviceID != identity.deviceID.value {
            let key = try await encryptKeyForDevice(
                contentKey: contentKey, jid: ownJID,
                deviceID: deviceID, identity: identity
            )
            keys.append(key)
        }
        let encrypted = buildEncryptedElement(
            keys: keys, payload: payload,
            senderDeviceID: identity.deviceID.value
        )
        let encryption = XMLElement(
            name: "encryption",
            namespace: XMPPNamespaces.eme,
            attributes: ["namespace": XMPPNamespaces.omemo, "name": "OMEMO"]
        )
        return EncryptedMessageElements(
            encrypted: encrypted,
            encryption: encryption,
            fallbackBody: "This message is OMEMO encrypted"
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
            node: node, itemID: "current",
            payload: payload, options: pepPublishOptions()
        )
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
        do {
            let result = try decryptIncomingMessage(
                encrypted, from: from
            )
            let context = state.withLock { $0.context }
            context?.emitEvent(.omemoEncryptedMessageReceived(
                from: from,
                decryptedBody: result.body,
                senderDeviceID: result.senderDeviceID
            ))
        } catch OMEMOModuleError.notForThisDevice {
            // Not addressed to us — ignore silently
        } catch {
            log.warning("OMEMO decryption failed: \(error)")
            let context = state.withLock { $0.context }
            context?.emitEvent(.omemoEncryptedMessageReceived(
                from: from, decryptedBody: nil, senderDeviceID: 0
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

    // periphery:ignore:parameters header - reserved for future MUC OMEMO sender validation
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
            $0.sessions[sessionKey] = updatedSession
            $0.sessionAD[sessionKey] = ad
            if let consumedPreKeyID {
                $0.usedPreKeyIDs.insert(consumedPreKeyID)
            }
            return $0.context
        }
        context?.emitEvent(.omemoSessionEstablished(
            jid: sessionKey.jid, deviceID: sessionKey.deviceID
        ))
        return plaintext
    }

    private func decryptExistingSessionKey(
        _ data: [UInt8], sessionKey: SessionKey
    ) throws -> [UInt8] {
        let ratchetMessage = try deserializeRatchetMessage(data)
        let (session, ad) = state.withLock {
            ($0.sessions[sessionKey], $0.sessionAD[sessionKey])
        }
        guard var session, let ad else {
            throw OMEMOModuleError.noSession
        }
        let plaintext = try session.decrypt(
            message: ratchetMessage, associatedData: ad
        )
        let updatedSession = session
        state.withLock { $0.sessions[sessionKey] = updatedSession }
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
    ) async throws -> XMLElement {
        let sessionKey = SessionKey(jid: jid, deviceID: deviceID)
        let result = try await getOrEstablishSession(
            sessionKey: sessionKey, identity: identity
        )
        var mutableSession = result.session
        let ratchetMessage = try mutableSession.encrypt(
            plaintext: contentKey, associatedData: result.ad
        )
        let updatedSession = mutableSession
        state.withLock {
            $0.sessions[sessionKey] = updatedSession
        }
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
        return buildKeyElement(
            deviceID: deviceID, data: serialized, isKex: isKex
        )
    }

    // MARK: - Session Management

    private func getOrEstablishSession(
        sessionKey: SessionKey, identity: OwnIdentity
    ) async throws -> SessionResult {
        let existing = state.withLock {
            ($0.sessions[sessionKey], $0.sessionAD[sessionKey])
        }
        if let session = existing.0, let ad = existing.1 {
            return SessionResult(
                session: session, ad: ad, kexInfo: nil
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
            $0.sessions[sessionKey] = session
            $0.sessionAD[sessionKey] = x3dhResult.associatedData
            return $0.context
        }
        context?.emitEvent(.omemoSessionEstablished(
            jid: sessionKey.jid, deviceID: sessionKey.deviceID
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
        "\(XMPPNamespaces.omemo):bundles:\(deviceID)"
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
