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
}

// MARK: - Helpers

private func makeModule() -> OMEMOModule {
    OMEMOModule(pepModule: PEPModule())
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
