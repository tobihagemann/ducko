import CryptoKit

/// Pre-key generation and bundle construction for OMEMO.
enum OMEMOPreKeyManager {
    // periphery:ignore - specced OMEMO constant, used by future OMEMOService
    /// Minimum number of pre-keys to include when publishing a bundle.
    static let minimumPreKeyCount = 25

    /// Target number of pre-keys to maintain in storage.
    static let targetPreKeyCount = 100

    /// Generates a batch of one-time pre-keys with sequential IDs.
    ///
    /// - Parameters:
    ///   - startID: The first key ID in the batch.
    ///   - count: Number of pre-keys to generate.
    /// - Returns: Array of freshly generated pre-keys.
    static func generatePreKeys(startID: UInt32, count: Int) -> [OMEMOPreKey] {
        (0 ..< count).map { offset in
            OMEMOPreKey(keyID: startID + UInt32(offset))
        }
    }

    /// Generates a signed pre-key, signed with the identity key.
    ///
    /// - Parameters:
    ///   - keyID: The key ID for the signed pre-key.
    ///   - identityKey: The identity key pair used to sign.
    /// - Returns: A freshly generated and signed pre-key.
    static func generateSignedPreKey(
        keyID: UInt32,
        identityKey: OMEMOIdentityKeyPair
    ) throws -> OMEMOSignedPreKey {
        try OMEMOSignedPreKey(keyID: keyID, identityKey: identityKey)
    }

    /// Builds a publishable OMEMO bundle from local key material.
    static func buildBundle(
        deviceID: OMEMODeviceID,
        identityKeyPair: OMEMOIdentityKeyPair,
        signedPreKey: OMEMOSignedPreKey,
        preKeys: [OMEMOPreKey]
    ) -> OMEMOBundle {
        OMEMOBundle(
            deviceID: deviceID,
            identityKey: identityKeyPair.publicKeyBytes,
            signedPreKeyID: signedPreKey.keyID,
            signedPreKey: signedPreKey.publicKeyBytes,
            signedPreKeySignature: signedPreKey.signature,
            preKeys: preKeys.map { OMEMOBundle.PreKeyPublic(id: $0.keyID, publicKey: $0.publicKeyBytes) }
        )
    }
}
