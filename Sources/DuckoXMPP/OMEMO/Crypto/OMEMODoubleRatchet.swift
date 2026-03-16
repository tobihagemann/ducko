import CryptoKit

/// Double Ratchet session state for OMEMO end-to-end encryption.
///
/// All state is value types for safe copying and persistence.
/// Use `mutating func` for encrypt/decrypt — the caller manages synchronization.
struct OMEMODoubleRatchetSession {
    /// Our current DH ratchet key pair (sending).
    var dhSendKeyPair: Curve25519.KeyAgreement.PrivateKey
    /// Cached public key bytes from `dhSendKeyPair`, recomputed only on ratchet step.
    var dhSendPublicKeyBytes: [UInt8]
    /// Peer's current DH ratchet public key (receiving), `nil` for responder before first message.
    var dhRecvPublicKey: [UInt8]?
    /// Root key (32 bytes).
    var rootKey: [UInt8]
    /// Sending chain key (32 bytes), `nil` until first send after DH ratchet.
    var sendChainKey: [UInt8]?
    /// Receiving chain key (32 bytes), `nil` until first receive.
    var recvChainKey: [UInt8]?
    /// Number of messages sent in the current sending chain.
    var sendMessageNumber: UInt32 = 0
    /// Number of messages received in the current receiving chain.
    var recvMessageNumber: UInt32 = 0
    /// Number of messages sent in the previous sending chain.
    var previousSendCount: UInt32 = 0
    /// Skipped message keys for out-of-order delivery.
    var skippedMessageKeys: [SkippedKeyID: [UInt8]] = [:]
    /// Insertion order for FIFO eviction of skipped keys.
    var skippedKeyOrder: [SkippedKeyID] = []

    /// Maximum number of skipped message keys to store.
    static let maxSkippedMessages = 1000

    // MARK: - Initialization

    /// Initializes as the initiator (Alice) after X3DH.
    ///
    /// - Parameters:
    ///   - sharedSecret: 32-byte shared secret from X3DH.
    ///   - peerSignedPreKey: Bob's signed pre-key (initial DHr).
    init(
        asInitiatorWithSharedSecret sharedSecret: [UInt8],
        peerSignedPreKey: [UInt8]
    ) throws {
        self.dhSendKeyPair = Curve25519.KeyAgreement.PrivateKey()
        self.dhSendPublicKeyBytes = Array(dhSendKeyPair.publicKey.rawRepresentation)
        self.dhRecvPublicKey = peerSignedPreKey
        self.rootKey = sharedSecret

        // Perform initial root key ratchet
        let peerPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerSignedPreKey)
        let dhOutput = try OMEMOCrypto.dh(privateKey: dhSendKeyPair, publicKey: peerPublicKey)
        let rk = OMEMOCrypto.kdfRK(rootKey: rootKey, dhOutput: dhOutput)
        self.rootKey = rk.rootKey
        self.sendChainKey = rk.chainKey
    }

    /// Initializes as the responder (Bob) after X3DH.
    ///
    /// - Parameters:
    ///   - sharedSecret: 32-byte shared secret from X3DH.
    ///   - ourSignedPreKeyPair: Our signed pre-key pair (initial DHs).
    init(
        asResponderWithSharedSecret sharedSecret: [UInt8],
        ourSignedPreKeyPair: Curve25519.KeyAgreement.PrivateKey
    ) {
        self.dhSendKeyPair = ourSignedPreKeyPair
        self.dhSendPublicKeyBytes = Array(ourSignedPreKeyPair.publicKey.rawRepresentation)
        self.dhRecvPublicKey = nil
        self.rootKey = sharedSecret
        self.sendChainKey = nil
        self.recvChainKey = nil
    }

    // MARK: - Encryption

    /// Encrypts a plaintext message, advancing the sending chain.
    ///
    /// - Parameters:
    ///   - plaintext: Message to encrypt.
    ///   - associatedData: AD from the X3DH handshake (64 bytes).
    /// - Returns: Ratchet message with header and encrypted payload.
    mutating func encrypt(
        plaintext: [UInt8],
        associatedData: [UInt8]
    ) throws -> OMEMORatchetMessage {
        guard let ck = sendChainKey else {
            throw OMEMOCryptoError.sessionNotInitialized
        }

        let ckResult = OMEMOCrypto.kdfCK(chainKey: ck)
        sendChainKey = ckResult.chainKey

        let header = OMEMORatchetHeader(
            dhPublicKey: dhSendPublicKeyBytes,
            previousChainCount: previousSendCount,
            messageNumber: sendMessageNumber
        )
        sendMessageNumber += 1

        let headerBytes = header.encode()
        let payload = try OMEMOMessageCrypto.encrypt(
            plaintext: plaintext,
            messageKey: ckResult.messageKey,
            associatedData: associatedData + headerBytes
        )

        return OMEMORatchetMessage(header: header, payload: payload)
    }

    // MARK: - Decryption

    /// Decrypts a received message, advancing the receiving chain and performing
    /// DH ratchet steps as needed.
    ///
    /// - Parameters:
    ///   - message: The received ratchet message.
    ///   - associatedData: AD from the X3DH handshake (64 bytes).
    /// - Returns: Decrypted plaintext bytes.
    mutating func decrypt(
        message: OMEMORatchetMessage,
        associatedData: [UInt8]
    ) throws -> [UInt8] {
        // 1. Try skipped message keys first
        let headerBytes = message.header.encode()
        let fullAD = associatedData + headerBytes

        if let plaintext = try trySkippedMessageKey(message: message, associatedData: fullAD) {
            return plaintext
        }

        // Snapshot state before advancing — rollback if authentication fails,
        // preventing a forged/corrupted packet from desynchronizing the session.
        let snapshot = self

        // 2. DH ratchet step if we received a new ratchet key
        if message.header.dhPublicKey != dhRecvPublicKey {
            try skipMessageKeys(until: message.header.previousChainCount)
            try dhRatchetStep(peerPublicKey: message.header.dhPublicKey)
        }

        // 3. Skip to the correct message number
        try skipMessageKeys(until: message.header.messageNumber)

        // 4. Advance the receiving chain
        guard let ck = recvChainKey else {
            throw OMEMOCryptoError.sessionNotInitialized
        }
        let ckResult = OMEMOCrypto.kdfCK(chainKey: ck)
        recvChainKey = ckResult.chainKey
        recvMessageNumber += 1

        // 5. Decrypt and verify — rollback on auth failure
        do {
            return try OMEMOMessageCrypto.decrypt(
                payload: message.payload,
                messageKey: ckResult.messageKey,
                associatedData: fullAD
            )
        } catch {
            self = snapshot
            throw error
        }
    }

    // MARK: - Private Ratchet Operations

    /// Attempts decryption using a previously skipped message key.
    private mutating func trySkippedMessageKey(
        message: OMEMORatchetMessage,
        associatedData: [UInt8]
    ) throws -> [UInt8]? {
        let keyID = SkippedKeyID(
            publicKey: message.header.dhPublicKey,
            messageNumber: message.header.messageNumber
        )

        guard let messageKey = skippedMessageKeys[keyID] else {
            return nil
        }

        // Decrypt BEFORE removing the key — if HMAC verification fails, the key
        // is preserved for retrying with the genuine (non-corrupted) message.
        let plaintext = try OMEMOMessageCrypto.decrypt(
            payload: message.payload,
            messageKey: messageKey,
            associatedData: associatedData
        )

        skippedMessageKeys.removeValue(forKey: keyID)
        skippedKeyOrder.removeAll { $0 == keyID }

        return plaintext
    }

    /// Advances skipped message keys for out-of-order delivery.
    private mutating func skipMessageKeys(until target: UInt32) throws {
        guard let ck = recvChainKey else { return }

        let toSkip = Int(target) - Int(recvMessageNumber)
        guard toSkip >= 0 else { return }
        guard toSkip <= Self.maxSkippedMessages else {
            throw OMEMOCryptoError.tooManySkippedMessages
        }

        var chainKey = ck
        for _ in recvMessageNumber ..< target {
            let result = OMEMOCrypto.kdfCK(chainKey: chainKey)
            let keyID = SkippedKeyID(publicKey: dhRecvPublicKey ?? [], messageNumber: recvMessageNumber)

            storeSkippedKey(id: keyID, messageKey: result.messageKey)
            chainKey = result.chainKey
            recvMessageNumber += 1
        }
        recvChainKey = chainKey
    }

    /// Stores a skipped message key, evicting the oldest if over the limit.
    private mutating func storeSkippedKey(id: SkippedKeyID, messageKey: [UInt8]) {
        skippedMessageKeys[id] = messageKey
        skippedKeyOrder.append(id)

        // FIFO eviction
        while skippedMessageKeys.count > Self.maxSkippedMessages {
            let oldest = skippedKeyOrder.removeFirst()
            skippedMessageKeys.removeValue(forKey: oldest)
        }
    }

    /// Performs a DH ratchet step when a new peer public key is received.
    private mutating func dhRatchetStep(peerPublicKey: [UInt8]) throws {
        previousSendCount = sendMessageNumber
        sendMessageNumber = 0
        recvMessageNumber = 0
        dhRecvPublicKey = peerPublicKey

        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)

        // Derive receiving chain key
        let dhRecv = try OMEMOCrypto.dh(privateKey: dhSendKeyPair, publicKey: peerKey)
        let rkRecv = OMEMOCrypto.kdfRK(rootKey: rootKey, dhOutput: dhRecv)
        rootKey = rkRecv.rootKey
        recvChainKey = rkRecv.chainKey

        // Generate new sending key pair and derive sending chain key
        dhSendKeyPair = Curve25519.KeyAgreement.PrivateKey()
        dhSendPublicKeyBytes = Array(dhSendKeyPair.publicKey.rawRepresentation)
        let dhSend = try OMEMOCrypto.dh(privateKey: dhSendKeyPair, publicKey: peerKey)
        let rkSend = OMEMOCrypto.kdfRK(rootKey: rootKey, dhOutput: dhSend)
        rootKey = rkSend.rootKey
        sendChainKey = rkSend.chainKey
    }

    // MARK: - Serialization

    /// Serializes the session state to bytes for persistent storage.
    func serialize() -> [UInt8] {
        var bytes: [UInt8] = []

        // DH send key pair (32 bytes)
        bytes.append(contentsOf: dhSendKeyPair.rawRepresentation)

        // DH recv public key: length (4 LE) + bytes
        if let recvKey = dhRecvPublicKey {
            appendLE(UInt32(recvKey.count), to: &bytes)
            bytes.append(contentsOf: recvKey)
        } else {
            appendLE(UInt32(0), to: &bytes)
        }

        // Root key (32 bytes)
        bytes.append(contentsOf: rootKey)

        // Send chain key: flag (1) + optional 32 bytes
        appendOptionalKey(sendChainKey, to: &bytes)

        // Recv chain key: flag (1) + optional 32 bytes
        appendOptionalKey(recvChainKey, to: &bytes)

        // Counters (4 LE each)
        appendLE(sendMessageNumber, to: &bytes)
        appendLE(recvMessageNumber, to: &bytes)
        appendLE(previousSendCount, to: &bytes)

        // Skipped keys: count (4 LE) + entries
        appendLE(UInt32(skippedKeyOrder.count), to: &bytes)
        for keyID in skippedKeyOrder {
            bytes.append(contentsOf: keyID.publicKey)
            appendLE(keyID.messageNumber, to: &bytes)
            if let messageKey = skippedMessageKeys[keyID] {
                bytes.append(contentsOf: messageKey)
            }
        }

        return bytes
    }

    /// Restores a session from previously serialized bytes.
    init(serialized bytes: [UInt8]) throws {
        var offset = 0

        func readBytes(_ count: Int) throws -> [UInt8] {
            guard offset + count <= bytes.count else { throw OMEMOCryptoError.invalidKeyLength }
            let result = Array(bytes[offset ..< offset + count])
            offset += count
            return result
        }

        func readLE() throws -> UInt32 {
            let b = try readBytes(4)
            return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        }

        // DH send key pair
        let sendKeyRaw = try readBytes(32)
        self.dhSendKeyPair = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: sendKeyRaw)
        self.dhSendPublicKeyBytes = Array(dhSendKeyPair.publicKey.rawRepresentation)

        // DH recv public key
        let recvKeyLen = try readLE()
        if recvKeyLen > 0 {
            self.dhRecvPublicKey = try readBytes(Int(recvKeyLen))
        } else {
            self.dhRecvPublicKey = nil
        }

        // Root key
        self.rootKey = try readBytes(32)

        // Send chain key
        let hasSendCK = try readBytes(1)[0]
        self.sendChainKey = hasSendCK != 0 ? try readBytes(32) : nil

        // Recv chain key
        let hasRecvCK = try readBytes(1)[0]
        self.recvChainKey = hasRecvCK != 0 ? try readBytes(32) : nil

        // Counters
        self.sendMessageNumber = try readLE()
        self.recvMessageNumber = try readLE()
        self.previousSendCount = try readLE()

        // Skipped keys
        let skippedCount = try readLE()
        self.skippedMessageKeys = [:]
        self.skippedKeyOrder = []
        for _ in 0 ..< skippedCount {
            let publicKey = try readBytes(32)
            let messageNumber = try readLE()
            let messageKey = try readBytes(32)
            let keyID = SkippedKeyID(publicKey: publicKey, messageNumber: messageNumber)
            skippedMessageKeys[keyID] = messageKey
            skippedKeyOrder.append(keyID)
        }
    }

    // MARK: - Serialization Helpers

    private func appendLE(_ value: UInt32, to buffer: inout [UInt8]) {
        buffer.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }

    private func appendOptionalKey(_ key: [UInt8]?, to buffer: inout [UInt8]) {
        if let key {
            buffer.append(1)
            buffer.append(contentsOf: key)
        } else {
            buffer.append(0)
        }
    }
}

// MARK: - Supporting Types

/// Identifier for a skipped message key: (ratchet public key, message number).
struct SkippedKeyID: Hashable {
    let publicKey: [UInt8]
    let messageNumber: UInt32

    func hash(into hasher: inout Hasher) {
        hasher.combine(publicKey)
        hasher.combine(messageNumber)
    }
}

/// A Double Ratchet message: header + encrypted payload.
struct OMEMORatchetMessage {
    let header: OMEMORatchetHeader
    let payload: OMEMOEncryptedPayload
}

/// Header of a Double Ratchet message.
struct OMEMORatchetHeader {
    /// Sender's current DH ratchet public key (32 bytes).
    let dhPublicKey: [UInt8]
    /// Number of messages in the previous sending chain.
    let previousChainCount: UInt32
    /// Message number in the current sending chain.
    let messageNumber: UInt32

    /// Encodes the header as bytes for inclusion in associated data.
    func encode() -> [UInt8] {
        var bytes = dhPublicKey
        bytes.append(contentsOf: withUnsafeBytes(of: previousChainCount.littleEndian) { Array($0) })
        bytes.append(contentsOf: withUnsafeBytes(of: messageNumber.littleEndian) { Array($0) })
        return bytes
    }
}
