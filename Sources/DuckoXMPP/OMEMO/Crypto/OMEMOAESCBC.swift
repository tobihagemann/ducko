import CommonCrypto

/// AES-256-CBC encryption and decryption with PKCS#7 padding via CommonCrypto.
enum OMEMOAESCBC {
    /// AES-256-CBC + PKCS#7. Requires 32-byte `key` and 16-byte `iv` (throws `invalidKeyLength`/`invalidIVLength`).
    static func encrypt(plaintext: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        guard key.count == kCCKeySizeAES256 else { throw OMEMOCryptoError.invalidKeyLength }
        guard iv.count == kCCBlockSizeAES128 else { throw OMEMOCryptoError.invalidIVLength }

        let bufferSize = plaintext.count + kCCBlockSizeAES128
        var output = [UInt8](repeating: 0, count: bufferSize)
        var numBytesEncrypted = 0

        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            key, key.count,
            iv,
            plaintext, plaintext.count,
            &output, bufferSize,
            &numBytesEncrypted
        )

        guard status == kCCSuccess else {
            throw OMEMOCryptoError.encryptionFailed(status: status)
        }

        return Array(output.prefix(numBytesEncrypted))
    }

    /// AES-256-CBC + PKCS#7 strip. Same key/IV size invariants as `encrypt`. Callers MUST verify MAC before calling (see `OMEMOMessageCrypto.decrypt`).
    static func decrypt(ciphertext: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        guard key.count == kCCKeySizeAES256 else { throw OMEMOCryptoError.invalidKeyLength }
        guard iv.count == kCCBlockSizeAES128 else { throw OMEMOCryptoError.invalidIVLength }

        var output = [UInt8](repeating: 0, count: ciphertext.count)
        var numBytesDecrypted = 0

        let status = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            key, key.count,
            iv,
            ciphertext, ciphertext.count,
            &output, output.count,
            &numBytesDecrypted
        )

        guard status == kCCSuccess else {
            throw OMEMOCryptoError.decryptionFailed(status: status)
        }

        return Array(output.prefix(numBytesDecrypted))
    }
}
