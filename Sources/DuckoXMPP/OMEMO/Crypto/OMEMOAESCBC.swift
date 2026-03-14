import CommonCrypto

/// AES-256-CBC encryption and decryption with PKCS#7 padding via CommonCrypto.
enum OMEMOAESCBC {
    /// Encrypts plaintext with AES-256-CBC and PKCS#7 padding.
    ///
    /// - Parameters:
    ///   - plaintext: Data to encrypt.
    ///   - key: 32-byte AES-256 key.
    ///   - iv: 16-byte initialization vector.
    /// - Returns: Ciphertext bytes.
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

    /// Decrypts AES-256-CBC ciphertext with PKCS#7 padding removal.
    ///
    /// - Parameters:
    ///   - ciphertext: Data to decrypt.
    ///   - key: 32-byte AES-256 key.
    ///   - iv: 16-byte initialization vector.
    /// - Returns: Plaintext bytes.
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
