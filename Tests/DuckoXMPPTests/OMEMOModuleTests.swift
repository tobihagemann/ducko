import Testing
@testable import DuckoXMPP

enum OMEMOModuleTests {
    // MARK: - Features

    struct Features {
        @Test func `advertises OMEMO and EME`() {
            let pepModule = PEPModule()
            let module = OMEMOModule(pepModule: pepModule)
            #expect(module.features.contains(XMPPNamespaces.omemo))
            #expect(module.features.contains(XMPPNamespaces.eme))
        }
    }

    // MARK: - Device List XML

    struct DeviceListTests {
        @Test func `parses device list XML`() {
            let xml = XMLElement(
                name: "list", namespace: XMPPNamespaces.omemo,
                children: [
                    .element(XMLElement(name: "device", attributes: ["id": "12345"])),
                    .element(XMLElement(name: "device", attributes: ["id": "67890"]))
                ]
            )
            let module = makeModule()
            let devices = module.parseDeviceList(xml)
            #expect(devices == [12345, 67890])
        }

        @Test func `parses empty device list`() {
            let xml = XMLElement(name: "list", namespace: XMPPNamespaces.omemo)
            let module = makeModule()
            let devices = module.parseDeviceList(xml)
            #expect(devices.isEmpty)
        }

        @Test func `skips invalid device I ds`() {
            let xml = XMLElement(
                name: "list", namespace: XMPPNamespaces.omemo,
                children: [
                    .element(XMLElement(name: "device", attributes: ["id": "123"])),
                    .element(XMLElement(name: "device", attributes: ["id": "notanumber"])),
                    .element(XMLElement(name: "device"))
                ]
            )
            let module = makeModule()
            let devices = module.parseDeviceList(xml)
            #expect(devices == [123])
        }
    }

    // MARK: - Bundle XML

    struct BundleTests {
        @Test func `round trips bundle XML`() throws {
            let bundle = makeTestBundle()
            let module = makeModule()
            let xml = module.buildBundleElement(bundle)
            let parsed = try #require(
                module.parseBundleElement(xml, deviceID: 42)
            )
            #expect(parsed.deviceID.value == 42)
            #expect(parsed.identityKey == bundle.identityKey)
            #expect(parsed.signedPreKey == bundle.signedPreKey)
            #expect(parsed.signedPreKeyID == bundle.signedPreKeyID)
            #expect(parsed.signedPreKeySignature == bundle.signedPreKeySignature)
            let parsedPKCount = parsed.preKeys.count
            #expect(parsedPKCount == bundle.preKeys.count)
            for (original, parsed) in zip(bundle.preKeys, parsed.preKeys) {
                #expect(original.id == parsed.id)
                #expect(original.publicKey == parsed.publicKey)
            }
        }

        @Test func `parses minimal bundle`() {
            let module = makeModule()
            // Missing prekeys element
            let xml = XMLElement(name: "bundle", namespace: XMPPNamespaces.omemo)
            let result = module.parseBundleElement(xml, deviceID: 1)
            #expect(result == nil)
        }
    }

    // MARK: - Key Serialization

    struct KeySerializationTests {
        @Test func `round trips ratchet message`() throws {
            let header = OMEMORatchetHeader(
                dhPublicKey: Array(repeating: 0xAB, count: 32),
                previousChainCount: 5,
                messageNumber: 10
            )
            let payload = OMEMOEncryptedPayload(
                ciphertext: [1, 2, 3, 4, 5],
                truncatedHMAC: Array(repeating: 0xCC, count: 16)
            )
            let original = OMEMORatchetMessage(
                header: header, payload: payload
            )
            let module = makeModule()
            let serialized = module.serializeRatchetMessage(original)
            let deserialized = try module.deserializeRatchetMessage(
                serialized
            )
            #expect(deserialized.header.dhPublicKey == header.dhPublicKey)
            #expect(deserialized.header.previousChainCount == 5)
            #expect(deserialized.header.messageNumber == 10)
            #expect(deserialized.payload.ciphertext == [1, 2, 3, 4, 5])
            #expect(deserialized.payload.truncatedHMAC == payload.truncatedHMAC)
        }

        @Test func `round trips key exchange`() throws {
            let header = OMEMORatchetHeader(
                dhPublicKey: Array(repeating: 0x11, count: 32),
                previousChainCount: 0,
                messageNumber: 0
            )
            let payload = OMEMOEncryptedPayload(
                ciphertext: Array(repeating: 0x22, count: 48),
                truncatedHMAC: Array(repeating: 0x33, count: 16)
            )
            let ratchetMsg = OMEMORatchetMessage(
                header: header, payload: payload
            )
            let identity = OMEMOIdentityKeyPair()
            let module = makeModule()
            // Build key exchange data manually (same format as OMEMOModule)
            var serialized: [UInt8] = []
            module.appendBigEndian(7, to: &serialized) // signedPreKeyID
            module.appendBigEndian(0xFFFF_FFFF, to: &serialized) // no OPK
            serialized.append(contentsOf: identity.publicKeyBytes)
            serialized.append(contentsOf: ratchetMsg.header.dhPublicKey)
            serialized.append(
                contentsOf: module.serializeRatchetMessage(ratchetMsg)
            )
            // Deserialize and verify
            guard serialized.count >= 72 + 40 + 16 else {
                Issue.record("Serialized data too short")
                return
            }
            let spkID = module.readBigEndian(serialized, offset: 0)
            let ik = Array(serialized[8 ..< 40])
            let ratchetData = Array(serialized[72...])
            let restored = try module.deserializeRatchetMessage(ratchetData)
            #expect(spkID == 7)
            #expect(ik == identity.publicKeyBytes)
            #expect(
                restored.header.dhPublicKey == header.dhPublicKey
            )
        }
    }

    // MARK: - SCE Envelope

    struct SCETests {
        @Test func `builds valid SCE envelope`() {
            let module = makeModule()
            let bytes = module.buildSCEEnvelope(body: "Hello")
            let xml = String(decoding: bytes, as: UTF8.self)
            let hasContent = xml.contains("<content")
            #expect(hasContent)
            let hasBody = xml.contains("Hello")
            #expect(hasBody)
            let hasRpad = xml.contains("<rpad>")
            #expect(hasRpad)
        }

        @Test func `extracts body from SCE`() {
            let module = makeModule()
            let bytes = module.buildSCEEnvelope(body: "Test message")
            let body = module.parseSCEBody(bytes)
            #expect(body == "Test message")
        }

        @Test func `round trips special characters`() {
            let module = makeModule()
            let bytes = module.buildSCEEnvelope(
                body: "Hello <world> & 'friends'"
            )
            let body = module.parseSCEBody(bytes)
            #expect(body == "Hello <world> & 'friends'")
        }
    }

    // MARK: - Encrypted Element Building

    struct EncryptedElementTests {
        @Test func `builds encrypted element`() {
            let module = makeModule()
            var key1 = XMLElement(
                name: "key", attributes: ["rid": "100"]
            )
            key1.addText("base64data")
            var key2 = XMLElement(
                name: "key",
                attributes: ["rid": "200", "kex": "true"]
            )
            key2.addText("kexdata")
            let encrypted = module.buildEncryptedElement(
                keys: [key1, key2],
                payload: "encryptedpayload",
                senderDeviceID: 42
            )
            #expect(encrypted.namespace == XMPPNamespaces.omemo)
            let header = encrypted.child(named: "header")
            #expect(header?.attribute("sid") == "42")
            let keys = header?.children(named: "key") ?? []
            let keyCount = keys.count
            #expect(keyCount == 2)
            let payloadEl = encrypted.child(named: "payload")
            #expect(payloadEl?.textContent == "encryptedpayload")
        }
    }

    // MARK: - End-to-End Encrypt/Decrypt

    struct EndToEndTests {
        @Test func `encrypt and decrypt content key`() throws {
            // Simulate: Alice encrypts a content key for Bob using
            // X3DH + Double Ratchet, then Bob decrypts it.
            let aliceIdentity = OMEMOIdentityKeyPair()
            let bobIdentity = OMEMOIdentityKeyPair()
            let bobSignedPreKey = try OMEMOPreKeyManager.generateSignedPreKey(
                keyID: 1, identityKey: bobIdentity
            )
            let bobPreKey = OMEMOPreKey(keyID: 1)
            let bobBundle = OMEMOPreKeyManager.buildBundle(
                deviceID: OMEMODeviceID(value: 200),
                identityKeyPair: bobIdentity,
                signedPreKey: bobSignedPreKey,
                preKeys: [bobPreKey]
            )
            let peerBundle = OMEMOX3DHPeerBundle(
                identityKey: bobBundle.identityKey,
                signedPreKey: bobBundle.signedPreKey,
                signedPreKeySignature: bobBundle.signedPreKeySignature,
                oneTimePreKey: bobBundle.preKeys.first?.publicKey
            )
            let aliceX3DH = try OMEMOX3DH.initiatorKeyAgreement(
                identityKeyPair: aliceIdentity,
                peerBundle: peerBundle
            )
            var aliceSession = try OMEMODoubleRatchetSession(
                asInitiatorWithSharedSecret: aliceX3DH.sharedSecret,
                peerSignedPreKey: bobBundle.signedPreKey
            )
            let contentKey: [UInt8] = (0 ..< 32).map { _ in
                UInt8.random(in: 0 ... 255)
            }
            let ratchetMessage = try aliceSession.encrypt(
                plaintext: contentKey,
                associatedData: aliceX3DH.associatedData
            )
            // Bob receives and decrypts
            let bobX3DH = try OMEMOX3DH.responderKeyAgreement(
                identityKeyPair: bobIdentity,
                signedPreKey: bobSignedPreKey,
                oneTimePreKey: bobPreKey,
                peerIdentityKey: aliceIdentity.publicKeyBytes,
                peerEphemeralKey: aliceX3DH.ephemeralPublicKey
            )
            var bobSession = OMEMODoubleRatchetSession(
                asResponderWithSharedSecret: bobX3DH.sharedSecret,
                ourSignedPreKeyPair: bobSignedPreKey.keyPair
            )
            let decrypted = try bobSession.decrypt(
                message: ratchetMessage,
                associatedData: bobX3DH.associatedData
            )
            #expect(decrypted == contentKey)
        }

        @Test func `full message encrypt decrypt`() throws {
            // Full flow: content key → encrypt payload → serialize →
            // deserialize → decrypt payload
            let contentKey: [UInt8] = (0 ..< 32).map { _ in
                UInt8.random(in: 0 ... 255)
            }
            let plaintext = Array("Hello, OMEMO!".utf8)
            let encrypted = try OMEMOMessageCrypto.encrypt(
                plaintext: plaintext, messageKey: contentKey,
                associatedData: []
            )
            let combined = encrypted.ciphertext + encrypted.truncatedHMAC
            let encoded = Base64.encode(combined)
            // Simulate wire: decode and split
            let decoded = try #require(Base64.decode(encoded))
            let ciphertext = Array(decoded.dropLast(16))
            let hmac = Array(decoded.suffix(16))
            let payload = OMEMOEncryptedPayload(
                ciphertext: ciphertext, truncatedHMAC: hmac
            )
            let decrypted = try OMEMOMessageCrypto.decrypt(
                payload: payload, messageKey: contentKey,
                associatedData: []
            )
            #expect(decrypted == plaintext)
        }

        @Test func `key serialization round trip`() throws {
            // Verify serialization/deserialization preserves ratchet
            // message data through base64 encoding
            let header = OMEMORatchetHeader(
                dhPublicKey: (0 ..< 32).map { _ in
                    UInt8.random(in: 0 ... 255)
                },
                previousChainCount: 3,
                messageNumber: 7
            )
            let payload = OMEMOEncryptedPayload(
                ciphertext: (0 ..< 64).map { _ in
                    UInt8.random(in: 0 ... 255)
                },
                truncatedHMAC: (0 ..< 16).map { _ in
                    UInt8.random(in: 0 ... 255)
                }
            )
            let message = OMEMORatchetMessage(
                header: header, payload: payload
            )
            let module = makeModule()
            let bytes = module.serializeRatchetMessage(message)
            let base64 = Base64.encode(bytes)
            let decoded = try #require(Base64.decode(base64))
            let restored = try module.deserializeRatchetMessage(decoded)
            #expect(restored.header.dhPublicKey == header.dhPublicKey)
            #expect(restored.header.previousChainCount == 3)
            #expect(restored.header.messageNumber == 7)
            #expect(restored.payload.ciphertext == payload.ciphertext)
            #expect(restored.payload.truncatedHMAC == payload.truncatedHMAC)
        }
    }

    // MARK: - Connect-Time Branches

    struct DeviceListFetchTests {
        @Test func `Cache miss issues PEP retrieve`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let (client, _) = try await makeConnectedClient(mock: mock, omemoModule: omemoModule, pepModule: pepModule)

            let task = Task { try await omemoModule.fetchDeviceList(for: peerJID) }

            await mock.waitForSent(count: 1)
            let iqID = try await #require(extractIQID(from: mock.sentBytes[0]))
            await mock.simulateReceive(makeDeviceListResultIQ(iqID: iqID, fromJID: peerJID, devices: [42, 43]))

            let devices = try await task.value
            #expect(devices == [42, 43])

            await client.disconnect()
        }

        @Test func `Cache hit returns without IQ`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let (client, _) = try await makeConnectedClient(mock: mock, omemoModule: omemoModule, pepModule: pepModule)

            // Prime the cache via the cache-miss flow.
            let primeTask = Task { try await omemoModule.fetchDeviceList(for: peerJID) }
            await mock.waitForSent(count: 1)
            let primeID = try await #require(extractIQID(from: mock.sentBytes[0]))
            await mock.simulateReceive(makeDeviceListResultIQ(iqID: primeID, fromJID: peerJID, devices: [42]))
            _ = try await primeTask.value

            let baseline = await mock.sentBytes.count

            // Second fetch (no force) should hit cache and NOT send an IQ.
            let cached = try await omemoModule.fetchDeviceList(for: peerJID)
            #expect(cached == [42])

            let after = await mock.sentBytes.count
            #expect(after == baseline)

            await client.disconnect()
        }

        @Test func `Force refresh emits omemoDeviceListReceived`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let (client, _) = try await makeConnectedClient(mock: mock, omemoModule: omemoModule, pepModule: pepModule)

            // Prime the cache so the upcoming call is a forced refresh, not a
            // cache miss (cache miss without force does NOT emit an event).
            let primeTask = Task { try await omemoModule.fetchDeviceList(for: peerJID) }
            await mock.waitForSent(count: 1)
            let primeID = try await #require(extractIQID(from: mock.sentBytes[0]))
            await mock.simulateReceive(makeDeviceListResultIQ(iqID: primeID, fromJID: peerJID, devices: [42]))
            _ = try await primeTask.value

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .omemoDeviceListReceived = event { return true }
                    return false
                }
            }

            let refreshTask = Task { try await omemoModule.fetchDeviceList(for: peerJID, forceRefresh: true) }
            await mock.waitForSent(count: 2)
            let refreshID = try await #require(extractIQID(from: mock.sentBytes[1]))
            await mock.simulateReceive(makeDeviceListResultIQ(iqID: refreshID, fromJID: peerJID, devices: [42, 99]))

            _ = try await refreshTask.value
            let collected = try await eventsTask.value
            guard case let .omemoDeviceListReceived(jid, devices) = try #require(collected.last) else {
                Issue.record("Expected omemoDeviceListReceived event")
                return
            }
            #expect(jid == peerJID)
            #expect(devices == [42, 99])

            await client.disconnect()
        }
    }

    struct EncryptKeysInParallelTests {
        @Test func `Skip device returning item-not-found yields single key`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let (client, _) = try await makeConnectedClient(mock: mock, omemoModule: omemoModule, pepModule: pepModule)

            let task = Task {
                try await omemoModule.encryptMessage(
                    plaintext: "hello", to: peerJID,
                    recipientDeviceIDs: [10, 11], ownDeviceIDs: []
                )
            }

            await mock.waitForSent(count: 2)
            let sent = await mock.sentBytes
            let id1 = try #require(extractIQID(from: sent[0]))
            let id2 = try #require(extractIQID(from: sent[1]))
            let dev2 = try #require(extractBundleDeviceID(from: sent[1]))

            // First fetch fails with item-not-found; second returns a valid bundle.
            await mock.simulateReceive(makeItemNotFoundIQ(iqID: id1, fromJID: peerJID))
            let validBundleIQ = try makeValidBundleResultIQ(
                iqID: id2, deviceID: dev2, fromJID: peerJID, module: omemoModule
            )
            await mock.simulateReceive(validBundleIQ)

            let elements = try await task.value
            let header = elements.encrypted.child(named: "header")
            let keys = header?.children(named: "key") ?? []
            #expect(keys.count == 1)
            #expect(keys.first?.attribute("rid") == "\(dev2)")

            await client.disconnect()
        }
    }

    struct NoUsableRecipientDevicesTests {
        @Test func `Empty recipient list throws`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let (client, _) = try await makeConnectedClient(mock: mock, omemoModule: omemoModule, pepModule: pepModule)

            await #expect(throws: OMEMOModuleError.noUsableRecipientDevices) {
                _ = try await omemoModule.encryptMessage(
                    plaintext: "hello", to: peerJID,
                    recipientDeviceIDs: [], ownDeviceIDs: []
                )
            }

            await client.disconnect()
        }

        @Test func `All recipients item-not-found throws`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let (client, _) = try await makeConnectedClient(mock: mock, omemoModule: omemoModule, pepModule: pepModule)

            let task = Task {
                try await omemoModule.encryptMessage(
                    plaintext: "hello", to: peerJID,
                    recipientDeviceIDs: [10, 11], ownDeviceIDs: []
                )
            }

            await mock.waitForSent(count: 2)
            let sent = await mock.sentBytes
            let id1 = try #require(extractIQID(from: sent[0]))
            let id2 = try #require(extractIQID(from: sent[1]))
            await mock.simulateReceive(makeItemNotFoundIQ(iqID: id1, fromJID: peerJID))
            await mock.simulateReceive(makeItemNotFoundIQ(iqID: id2, fromJID: peerJID))

            await #expect(throws: OMEMOModuleError.noUsableRecipientDevices) {
                _ = try await task.value
            }

            await client.disconnect()
        }
    }

    struct PublishOptionsTests {
        @Test func `Bundle publish IQ contains XEP-0223 publish-options form`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let (client, artifacts) = try await makeConnectedClient(
                mock: mock, omemoModule: omemoModule, pepModule: pepModule
            )

            let bundleIQ = String(decoding: artifacts.bundlePublishIQ, as: UTF8.self)

            #expect(bundleIQ.contains("publish-options"))
            #expect(bundleIQ.contains("var=\"FORM_TYPE\""))
            #expect(bundleIQ.contains("<value>http://jabber.org/protocol/pubsub#publish-options</value>"))
            #expect(bundleIQ.contains("var=\"pubsub#persist_items\""))
            // The persist_items value follows its field — assert presence of "true" within the form.
            #expect(bundleIQ.contains("<value>true</value>"))
            #expect(bundleIQ.contains("var=\"pubsub#access_model\""))
            #expect(bundleIQ.contains("<value>open</value>"))
            // Bundle publish uses pepPublishOptions() with no maxItems argument.
            #expect(!bundleIQ.contains("var=\"pubsub#max_items\""))

            // The device-list publish DOES carry max_items=1.
            let deviceListIQ = String(decoding: artifacts.deviceListPublishIQ, as: UTF8.self)
            #expect(deviceListIQ.contains("var=\"pubsub#max_items\""))
            #expect(deviceListIQ.contains("<value>1</value>"))

            await client.disconnect()
        }
    }
}

// MARK: - Helpers

private func makeModule() -> OMEMOModule {
    OMEMOModule(pepModule: PEPModule())
}

/// The two connect-time PEP publish IQ stanzas captured by
/// `makeConnectedClient` before it clears the mock's sent buffer. Tests inspect
/// these directly instead of indexing into post-handshake `mock.sentBytes`
/// offsets. The own device-list retrieve IQ is consumed during connect and not
/// surfaced — add it here if a future test needs to inspect it.
private struct OMEMOConnectArtifacts {
    let deviceListPublishIQ: [UInt8]
    let bundlePublishIQ: [UInt8]
}

/// Drives the standard handshake (4 stanzas) followed by OMEMO's connect-time
/// PEP IQ flow: own device-list retrieve, device-list publish, bundle publish.
/// After this returns, `omemoModule.ownIdentityData` is populated. The mock's
/// `sentBytes` is cleared so post-handshake tests can index from 0; the two
/// publish IQ byte buffers (device-list publish, bundle publish) are returned
/// via `OMEMOConnectArtifacts`. The own-device-list retrieve IQ is consumed
/// in-place and not surfaced.
private func makeConnectedClient(
    mock: MockTransport,
    omemoModule: OMEMOModule,
    pepModule: PEPModule
) async throws -> (XMPPClient, OMEMOConnectArtifacts) {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(pepModule)
    await client.register(omemoModule)

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)

    // PEP retrieve own device list. Empty result → module appends its
    // freshly generated device ID and publishes.
    await mock.waitForSent(count: 5)
    let id5 = try await #require(extractIQID(from: mock.sentBytes[4]))
    await mock.simulateReceive("<iq type=\"result\" id=\"\(id5)\"/>")

    // Device list publish.
    await mock.waitForSent(count: 6)
    let deviceListPublishIQ = await mock.sentBytes[5]
    let id6 = try #require(extractIQID(from: deviceListPublishIQ))
    await mock.simulateReceive("<iq type=\"result\" id=\"\(id6)\"/>")

    // Own bundle publish.
    await mock.waitForSent(count: 7)
    let bundlePublishIQ = await mock.sentBytes[6]
    let id7 = try #require(extractIQID(from: bundlePublishIQ))
    await mock.simulateReceive("<iq type=\"result\" id=\"\(id7)\"/>")

    try await connectTask.value
    await mock.clearSentBytes()

    return (client, OMEMOConnectArtifacts(
        deviceListPublishIQ: deviceListPublishIQ,
        bundlePublishIQ: bundlePublishIQ
    ))
}

private let peerJID = BareJID(localPart: "peer", domainPart: "example.com")!

/// Builds a `<iq type='result'>` carrying a device-list payload for the given
/// device IDs.
private func makeDeviceListResultIQ(iqID: String, fromJID: BareJID, devices: [UInt32]) -> String {
    var deviceXML = ""
    for id in devices {
        deviceXML += "<device id=\"\(id)\"/>"
    }
    return """
    <iq type="result" id="\(iqID)" from="\(fromJID.description)">\
    <pubsub xmlns="http://jabber.org/protocol/pubsub">\
    <items node="urn:xmpp:omemo:2:devices">\
    <item id="current"><list xmlns="urn:xmpp:omemo:2">\(deviceXML)</list></item>\
    </items></pubsub></iq>
    """
}

/// Builds a `<iq type='error'>` with `<item-not-found/>` for the given id.
private func makeItemNotFoundIQ(iqID: String, fromJID: BareJID) -> String {
    """
    <iq type="error" id="\(iqID)" from="\(fromJID.description)">\
    <error type="cancel">\
    <item-not-found xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/>\
    </error></iq>
    """
}

/// Builds a `<iq type='result'>` carrying a freshly-generated valid OMEMO
/// bundle for the given peer device, suitable for X3DH initiator agreement.
private func makeValidBundleResultIQ(
    iqID: String, deviceID: UInt32, fromJID: BareJID, module: OMEMOModule
) throws -> String {
    let identityKeyPair = OMEMOIdentityKeyPair()
    let signedPreKey = try OMEMOPreKeyManager.generateSignedPreKey(
        keyID: 1, identityKey: identityKeyPair
    )
    let preKey = OMEMOPreKey(keyID: 1)
    let bundle = OMEMOPreKeyManager.buildBundle(
        deviceID: OMEMODeviceID(value: deviceID),
        identityKeyPair: identityKeyPair,
        signedPreKey: signedPreKey,
        preKeys: [preKey]
    )
    let bundleEl = module.buildBundleElement(bundle)
    return """
    <iq type="result" id="\(iqID)" from="\(fromJID.description)">\
    <pubsub xmlns="http://jabber.org/protocol/pubsub">\
    <items node="urn:xmpp:omemo:2:bundles:\(deviceID)">\
    <item id="current">\(bundleEl.xmlString)</item>\
    </items></pubsub></iq>
    """
}

/// Extracts the bundle device ID from a captured `<iq>` whose pubsub items
/// reference the bundle node `urn:xmpp:omemo:2:bundles:<deviceID>`.
private func extractBundleDeviceID(from bytes: [UInt8]) -> UInt32? {
    let xml = String(decoding: bytes, as: UTF8.self)
    let prefix = "urn:xmpp:omemo:2:bundles:"
    guard let nodeRange = xml.range(of: "node=\"\(prefix)") else { return nil }
    let after = xml[nodeRange.upperBound...]
    guard let endQuote = after.firstIndex(of: "\"") else { return nil }
    return UInt32(after[after.startIndex ..< endQuote])
}

private func makeTestBundle() -> OMEMOBundle {
    OMEMOBundle(
        deviceID: OMEMODeviceID(value: 42),
        identityKey: Array(repeating: 0x01, count: 32),
        signedPreKeyID: 1,
        signedPreKey: Array(repeating: 0x02, count: 32),
        signedPreKeySignature: Array(repeating: 0x03, count: 64),
        preKeys: [
            OMEMOBundle.PreKeyPublic(
                id: 1, publicKey: Array(repeating: 0x04, count: 32)
            ),
            OMEMOBundle.PreKeyPublic(
                id: 2, publicKey: Array(repeating: 0x05, count: 32)
            )
        ]
    )
}
