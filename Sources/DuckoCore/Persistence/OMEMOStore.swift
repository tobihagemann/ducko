import Foundation

// MARK: - Domain Types

public struct OMEMOStoredIdentity: Sendable {
    public let accountJID: String
    public let deviceID: UInt32
    public let identityKeyData: Data
    public let registrationID: UInt32

    public init(accountJID: String, deviceID: UInt32, identityKeyData: Data, registrationID: UInt32) {
        self.accountJID = accountJID
        self.deviceID = deviceID
        self.identityKeyData = identityKeyData
        self.registrationID = registrationID
    }
}

public struct OMEMOStoredPreKey: Sendable {
    public let accountJID: String
    public let keyID: UInt32
    public let keyData: Data
    public let isUsed: Bool

    public init(accountJID: String, keyID: UInt32, keyData: Data, isUsed: Bool) {
        self.accountJID = accountJID
        self.keyID = keyID
        self.keyData = keyData
        self.isUsed = isUsed
    }
}

public struct OMEMOStoredSignedPreKey: Sendable {
    public let accountJID: String
    public let keyID: UInt32
    public let keyData: Data
    public let signature: Data
    public let timestamp: Date

    public init(accountJID: String, keyID: UInt32, keyData: Data, signature: Data, timestamp: Date) {
        self.accountJID = accountJID
        self.keyID = keyID
        self.keyData = keyData
        self.signature = signature
        self.timestamp = timestamp
    }
}

public struct OMEMOStoredSession: Sendable {
    public let accountJID: String
    public let peerJID: String
    public let peerDeviceID: UInt32
    public let sessionData: Data
    public let associatedData: Data

    public init(accountJID: String, peerJID: String, peerDeviceID: UInt32, sessionData: Data, associatedData: Data) {
        self.accountJID = accountJID
        self.peerJID = peerJID
        self.peerDeviceID = peerDeviceID
        self.sessionData = sessionData
        self.associatedData = associatedData
    }
}

public struct OMEMOTrust: Sendable {
    public let accountJID: String
    public let peerJID: String
    public let deviceID: UInt32
    public let fingerprint: String
    public let trustLevel: OMEMOTrustLevel

    public init(accountJID: String, peerJID: String, deviceID: UInt32, fingerprint: String, trustLevel: OMEMOTrustLevel) {
        self.accountJID = accountJID
        self.peerJID = peerJID
        self.deviceID = deviceID
        self.fingerprint = fingerprint
        self.trustLevel = trustLevel
    }
}

public enum OMEMOTrustLevel: String, Sendable, Codable {
    case undecided
    case trusted
    case untrusted
    case verified

    /// Whether this trust level allows encrypting messages to the device.
    public var isTrustedForEncryption: Bool {
        self == .trusted || self == .verified
    }

    /// Whether this trust level allows encrypting, respecting the TOFU preference.
    public func isTrustedForEncryption(trustOnFirstUse: Bool) -> Bool {
        switch self {
        case .trusted, .verified: true
        case .undecided: trustOnFirstUse
        case .untrusted: false
        }
    }
}

// MARK: - Protocol

public protocol OMEMOStore: Sendable {
    // MARK: - Identity

    func loadIdentity(for accountJID: String) async throws -> OMEMOStoredIdentity?
    func saveIdentity(_ identity: OMEMOStoredIdentity) async throws

    // MARK: - Pre-Keys

    func loadPreKeys(for accountJID: String) async throws -> [OMEMOStoredPreKey]
    func savePreKeys(_ preKeys: [OMEMOStoredPreKey]) async throws
    func consumePreKey(id: UInt32, accountJID: String) async throws

    // MARK: - Signed Pre-Key

    func loadSignedPreKey(for accountJID: String) async throws -> OMEMOStoredSignedPreKey?
    func saveSignedPreKey(_ key: OMEMOStoredSignedPreKey) async throws

    // MARK: - Sessions

    func loadSessions(for accountJID: String) async throws -> [OMEMOStoredSession]
    func saveSession(_ session: OMEMOStoredSession) async throws

    // MARK: - Trust

    func saveTrust(_ trust: OMEMOTrust) async throws
    func loadTrust(accountJID: String, peerJID: String, deviceID: UInt32) async throws -> OMEMOTrust?
    func loadAllTrustedDevices(for peerJID: String, accountJID: String) async throws -> [OMEMOTrust]
}
