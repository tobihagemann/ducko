import CryptoKit

/// Extended Triple Diffie-Hellman (X3DH) key agreement protocol for OMEMO.
///
/// Both initiator and responder derive the same shared secret and associated data,
/// which are then used to initialize a Double Ratchet session.
enum OMEMOX3DH {
    /// Initiator (Alice) computes a shared secret from the peer's published bundle.
    ///
    /// - Parameters:
    ///   - identityKeyPair: Our Ed25519 identity key pair.
    ///   - peerBundle: The peer's published key material.
    /// - Returns: Shared secret and associated data for Double Ratchet initialization.
    static func initiatorKeyAgreement(
        identityKeyPair: OMEMOIdentityKeyPair,
        peerBundle: OMEMOX3DHPeerBundle
    ) throws -> X3DHResult {
        // 1. Verify the signed pre-key signature
        guard try verifySignedPreKey(
            signedPreKeyPublic: peerBundle.signedPreKey,
            signature: peerBundle.signedPreKeySignature,
            identityKey: peerBundle.identityKey
        ) else {
            throw OMEMOCryptoError.invalidSignature
        }

        // 2. Convert identity keys to X25519 for DH
        let ourAgreementKey = try identityKeyPair.agreementPrivateKey()
        let peerIdentityX25519 = try x25519PublicKey(fromEd25519: peerBundle.identityKey)
        let peerSPK = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerBundle.signedPreKey)

        // 3. Generate ephemeral key pair
        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()

        // 4. Perform DH operations and derive shared secret
        let dhOutput = try performDHOperations(
            ourIdentityKey: ourAgreementKey,
            ephemeralKey: ephemeralKey,
            peerIdentityKey: peerIdentityX25519,
            peerSignedPreKey: peerSPK,
            peerOneTimePreKey: peerBundle.oneTimePreKey
        )

        let result = deriveSharedSecret(
            dhOutput: dhOutput,
            initiatorIdentityKey: identityKeyPair.publicKeyBytes,
            responderIdentityKey: peerBundle.identityKey
        )

        return X3DHResult(
            sharedSecret: result.sharedSecret,
            associatedData: result.associatedData,
            ephemeralPublicKey: Array(ephemeralKey.publicKey.rawRepresentation)
        )
    }

    /// Responder (Bob) computes a shared secret from the initiator's initial message.
    static func responderKeyAgreement(
        identityKeyPair: OMEMOIdentityKeyPair,
        signedPreKey: OMEMOSignedPreKey,
        oneTimePreKey: OMEMOPreKey?,
        peerIdentityKey: [UInt8],
        peerEphemeralKey: [UInt8]
    ) throws -> X3DHResult {
        let ourAgreementKey = try identityKeyPair.agreementPrivateKey()
        let peerIdentityX25519 = try x25519PublicKey(fromEd25519: peerIdentityKey)
        let peerEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphemeralKey)

        // DH operations mirrored from initiator
        let dh1 = try OMEMOCrypto.dh(privateKey: signedPreKey.keyPair, publicKey: peerIdentityX25519)
        let dh2 = try OMEMOCrypto.dh(privateKey: ourAgreementKey, publicKey: peerEphemeral)
        let dh3 = try OMEMOCrypto.dh(privateKey: signedPreKey.keyPair, publicKey: peerEphemeral)

        var dhOutput = dh1 + dh2 + dh3
        if let opk = oneTimePreKey {
            let dh4 = try OMEMOCrypto.dh(privateKey: opk.keyPair, publicKey: peerEphemeral)
            dhOutput += dh4
        }

        let result = deriveSharedSecret(
            dhOutput: dhOutput,
            initiatorIdentityKey: peerIdentityKey,
            responderIdentityKey: identityKeyPair.publicKeyBytes
        )

        return X3DHResult(
            sharedSecret: result.sharedSecret,
            associatedData: result.associatedData,
            ephemeralPublicKey: peerEphemeralKey
        )
    }

    /// Validates a signed pre-key's Ed25519 signature against the identity key.
    static func verifySignedPreKey(
        signedPreKeyPublic: [UInt8],
        signature: [UInt8],
        identityKey: [UInt8]
    ) throws -> Bool {
        let edPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: identityKey)
        return edPublicKey.isValidSignature(signature, for: signedPreKeyPublic)
    }

    // MARK: - Private

    /// Performs the 3 or 4 DH operations for the initiator side.
    private static func performDHOperations(
        ourIdentityKey: Curve25519.KeyAgreement.PrivateKey,
        ephemeralKey: Curve25519.KeyAgreement.PrivateKey,
        peerIdentityKey: Curve25519.KeyAgreement.PublicKey,
        peerSignedPreKey: Curve25519.KeyAgreement.PublicKey,
        peerOneTimePreKey: [UInt8]?
    ) throws -> [UInt8] {
        let dh1 = try OMEMOCrypto.dh(privateKey: ourIdentityKey, publicKey: peerSignedPreKey)
        let dh2 = try OMEMOCrypto.dh(privateKey: ephemeralKey, publicKey: peerIdentityKey)
        let dh3 = try OMEMOCrypto.dh(privateKey: ephemeralKey, publicKey: peerSignedPreKey)

        var dhOutput = dh1 + dh2 + dh3

        if let opkBytes = peerOneTimePreKey {
            let opk = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: opkBytes)
            let dh4 = try OMEMOCrypto.dh(privateKey: ephemeralKey, publicKey: opk)
            dhOutput += dh4
        }

        return dhOutput
    }

    /// Derives shared secret and associated data from concatenated DH outputs.
    private static func deriveSharedSecret(
        dhOutput: [UInt8],
        initiatorIdentityKey: [UInt8],
        responderIdentityKey: [UInt8]
    ) -> DerivedSecret {
        // IKM = 32 bytes of 0xFF || DH outputs
        let ikm = [UInt8](repeating: 0xFF, count: 32) + dhOutput

        let sharedSecret = OMEMOCrypto.hkdfSHA256(
            inputKeyMaterial: ikm,
            salt: [UInt8](repeating: 0, count: 32),
            info: Array("OMEMO X3DH".utf8),
            outputByteCount: 32
        )

        // AD = Encode(IK_A) || Encode(IK_B), both Ed25519 public keys (64 bytes total)
        let associatedData = initiatorIdentityKey + responderIdentityKey

        return DerivedSecret(sharedSecret: sharedSecret, associatedData: associatedData)
    }

    /// Converts an Ed25519 public key to an X25519 public key via the birational map.
    private static func x25519PublicKey(
        fromEd25519 edKey: [UInt8]
    ) throws -> Curve25519.KeyAgreement.PublicKey {
        guard let x25519Bytes = OMEMOCurveConversion.ed25519ToX25519(edKey) else {
            throw OMEMOCryptoError.invalidPublicKey
        }
        return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: x25519Bytes)
    }

    // MARK: - Types

    private struct DerivedSecret {
        let sharedSecret: [UInt8]
        let associatedData: [UInt8]
    }
}

// MARK: - Public Types

/// Peer's published key material for X3DH key agreement.
struct OMEMOX3DHPeerBundle {
    /// Ed25519 public key (32 bytes).
    let identityKey: [UInt8]
    /// X25519 public key (32 bytes).
    let signedPreKey: [UInt8]
    /// Ed25519 signature over the signed pre-key (64 bytes).
    let signedPreKeySignature: [UInt8]
    /// X25519 public key (32 bytes), optional.
    let oneTimePreKey: [UInt8]?
}

/// Result of an X3DH key agreement.
struct X3DHResult {
    /// Shared secret for Double Ratchet initialization (32 bytes).
    let sharedSecret: [UInt8]
    /// Associated data: Encode(IK_A) || Encode(IK_B) (64 bytes).
    let associatedData: [UInt8]
    /// Ephemeral public key sent/received in the initial message (32 bytes).
    let ephemeralPublicKey: [UInt8]
}
