import Foundation

/// JSON-serializable mirror of `OMEMOModule.OMEMOIdentityData` used only by the
/// integration-test fixture flow. `OMEMOIdentityData` itself is not `Codable`
/// in production; this struct keeps the `Codable` dependency test-only.
///
/// Encoded as plain int-arrays (no base64) so fixture drift is visible to the
/// naked eye when inspecting the JSON.
struct FixtureOMEMOIdentity: Codable {
    let deviceID: UInt32
    /// Ed25519 seed (32 bytes).
    let identityKeyRaw: [UInt8]
    let signedPreKeyID: UInt32
    /// X25519 private key raw (32 bytes).
    let signedPreKeyRaw: [UInt8]
    /// Ed25519 signature over the signed pre-key (64 bytes).
    let signedPreKeySignature: [UInt8]
    let preKeys: [PreKey]
    /// Bare JID this fixture was captured for. Optional with `decodeIfPresent`
    /// so legacy fixtures (written before this field existed) keep loading;
    /// `loadOMEMOFixture` refuses a fixture whose JID disagrees with the
    /// credential at load time so identity material cannot be silently reused
    /// across accounts.
    let accountJID: String?

    init(
        deviceID: UInt32,
        identityKeyRaw: [UInt8],
        signedPreKeyID: UInt32,
        signedPreKeyRaw: [UInt8],
        signedPreKeySignature: [UInt8],
        preKeys: [PreKey],
        accountJID: String? = nil
    ) {
        self.deviceID = deviceID
        self.identityKeyRaw = identityKeyRaw
        self.signedPreKeyID = signedPreKeyID
        self.signedPreKeyRaw = signedPreKeyRaw
        self.signedPreKeySignature = signedPreKeySignature
        self.preKeys = preKeys
        self.accountJID = accountJID
    }

    /// Custom decode so legacy fixtures — written before `accountJID` existed —
    /// deserialize cleanly with `accountJID = nil` rather than throwing
    /// `keyNotFound`. Mirrors `PreKey.init(from:)` for the same reason.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.deviceID = try container.decode(UInt32.self, forKey: .deviceID)
        self.identityKeyRaw = try container.decode([UInt8].self, forKey: .identityKeyRaw)
        self.signedPreKeyID = try container.decode(UInt32.self, forKey: .signedPreKeyID)
        self.signedPreKeyRaw = try container.decode([UInt8].self, forKey: .signedPreKeyRaw)
        self.signedPreKeySignature = try container.decode([UInt8].self, forKey: .signedPreKeySignature)
        self.preKeys = try container.decode([PreKey].self, forKey: .preKeys)
        self.accountJID = try container.decodeIfPresent(String.self, forKey: .accountJID)
    }

    struct PreKey: Codable {
        let keyID: UInt32
        /// X25519 private key raw (32 bytes).
        let keyRaw: [UInt8]
        /// Round-tripped so a prekey consumed in a prior run stays consumed on
        /// replay — re-advertising a used prekey can trip strict OMEMO peers.
        /// Defaults to `false` so legacy fixtures load without rewriting.
        var isUsed: Bool = false

        init(keyID: UInt32, keyRaw: [UInt8], isUsed: Bool = false) {
            self.keyID = keyID
            self.keyRaw = keyRaw
            self.isUsed = isUsed
        }

        /// Custom decode so legacy fixtures — written before `isUsed` existed —
        /// deserialize cleanly with `isUsed = false` rather than throwing
        /// `keyNotFound`. Swift's synthesized `Codable` ignores stored-property
        /// default values on decode.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.keyID = try container.decode(UInt32.self, forKey: .keyID)
            self.keyRaw = try container.decode([UInt8].self, forKey: .keyRaw)
            self.isUsed = try container.decodeIfPresent(Bool.self, forKey: .isUsed) ?? false
        }
    }

    /// Shape invariants matching `OMEMOModule.OMEMOIdentityData` field docs.
    /// Guards against partial writes and byte-count drift from older fixture
    /// format revisions — a decoded-but-unusable fixture would otherwise be
    /// re-seeded each run and silently fail inside `handleConnect`.
    var passesShapeInvariants: Bool {
        !preKeys.isEmpty
            && identityKeyRaw.count == 32
            && signedPreKeyRaw.count == 32
            && signedPreKeySignature.count == 64
            && preKeys.allSatisfy { $0.keyRaw.count == 32 }
    }
}
