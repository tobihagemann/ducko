import CryptoKit

/// OMEMO message envelope encryption and decryption.
///
/// Derives AES key + HMAC key + IV from a message key, encrypts/decrypts
/// the payload with AES-256-CBC, and computes/verifies a truncated HMAC.
enum OMEMOMessageCrypto {
    /// Encrypts a plaintext message using the given message key.
    ///
    /// - Parameters:
    ///   - plaintext: The message to encrypt.
    ///   - messageKey: 32-byte key from the Double Ratchet chain.
    ///   - associatedData: AD for HMAC authentication (not encrypted).
    /// - Returns: Encrypted payload with ciphertext and truncated HMAC.
    static func encrypt(
        plaintext: [UInt8],
        messageKey: [UInt8],
        associatedData: [UInt8]
    ) throws -> OMEMOEncryptedPayload {
        let keys = deriveMessageKeys(messageKey)
        let ciphertext = try OMEMOAESCBC.encrypt(plaintext: plaintext, key: keys.aesKey, iv: keys.iv)
        let hmac = computeTruncatedHMAC(hmacKey: keys.hmacKey, associatedData: associatedData, ciphertext: ciphertext)
        return OMEMOEncryptedPayload(ciphertext: ciphertext, truncatedHMAC: hmac)
    }

    /// Decrypts an encrypted payload, verifying the HMAC first.
    ///
    /// - Parameters:
    ///   - payload: The encrypted payload to decrypt.
    ///   - messageKey: 32-byte key from the Double Ratchet chain.
    ///   - associatedData: AD that was used during encryption.
    /// - Returns: Decrypted plaintext bytes.
    static func decrypt(
        payload: OMEMOEncryptedPayload,
        messageKey: [UInt8],
        associatedData: [UInt8]
    ) throws -> [UInt8] {
        let keys = deriveMessageKeys(messageKey)

        // Verify HMAC before decrypting
        let expectedHMAC = computeTruncatedHMAC(
            hmacKey: keys.hmacKey,
            associatedData: associatedData,
            ciphertext: payload.ciphertext
        )
        guard constantTimeEqual(payload.truncatedHMAC, expectedHMAC) else {
            throw OMEMOCryptoError.hmacVerificationFailed
        }

        return try OMEMOAESCBC.decrypt(ciphertext: payload.ciphertext, key: keys.aesKey, iv: keys.iv)
    }

    // MARK: - Private

    /// Derives AES key (32), HMAC key (32), and IV (16) from a message key.
    private static func deriveMessageKeys(_ messageKey: [UInt8]) -> MessageKeys {
        let derived = OMEMOCrypto.hkdfSHA256(
            inputKeyMaterial: messageKey,
            salt: [UInt8](repeating: 0, count: 32),
            info: Array("omemo-message".utf8),
            outputByteCount: 80
        )
        return MessageKeys(
            aesKey: Array(derived[0 ..< 32]),
            hmacKey: Array(derived[32 ..< 64]),
            iv: Array(derived[64 ..< 80])
        )
    }

    /// Computes HMAC-SHA256 over AD || ciphertext, truncated to 16 bytes.
    private static func computeTruncatedHMAC(
        hmacKey: [UInt8],
        associatedData: [UInt8],
        ciphertext: [UInt8]
    ) -> [UInt8] {
        let fullHMAC = OMEMOCrypto.hmacSHA256(key: hmacKey, data: associatedData + ciphertext)
        return Array(fullHMAC.prefix(16))
    }

    /// Constant-time comparison to prevent timing attacks.
    private static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for i in 0 ..< a.count {
            result |= a[i] ^ b[i]
        }
        return result == 0
    }

    private struct MessageKeys {
        let aesKey: [UInt8]
        let hmacKey: [UInt8]
        let iv: [UInt8]
    }
}

/// An OMEMO encrypted message payload: ciphertext + truncated HMAC tag.
struct OMEMOEncryptedPayload {
    let ciphertext: [UInt8]
    /// HMAC-SHA256 truncated to 16 bytes.
    let truncatedHMAC: [UInt8]
}
