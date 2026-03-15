import DuckoCore
import Foundation
import SwiftData

@ModelActor
public actor SwiftDataOMEMOStore: OMEMOStore {
    // MARK: - Identity

    public func loadIdentity(for accountJID: String) throws -> OMEMOStoredIdentity? {
        var descriptor = FetchDescriptor<OMEMOIdentityRecord>(
            predicate: #Predicate { $0.accountJID == accountJID }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return nil }
        return OMEMOStoredIdentity(
            accountJID: record.accountJID,
            deviceID: UInt32(record.deviceID),
            identityKeyData: record.identityKeyData,
            registrationID: UInt32(record.registrationID)
        )
    }

    public func saveIdentity(_ identity: OMEMOStoredIdentity) throws {
        let accountJID = identity.accountJID
        var descriptor = FetchDescriptor<OMEMOIdentityRecord>(
            predicate: #Predicate { $0.accountJID == accountJID }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.deviceID = Int64(identity.deviceID)
            existing.identityKeyData = identity.identityKeyData
            existing.registrationID = Int64(identity.registrationID)
        } else {
            let record = OMEMOIdentityRecord(
                id: UUID(),
                accountJID: identity.accountJID,
                deviceID: Int64(identity.deviceID),
                identityKeyData: identity.identityKeyData,
                registrationID: Int64(identity.registrationID)
            )
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    // MARK: - Pre-Keys

    public func loadPreKeys(for accountJID: String) throws -> [OMEMOStoredPreKey] {
        let descriptor = FetchDescriptor<OMEMOPreKeyRecord>(
            predicate: #Predicate { $0.accountJID == accountJID }
        )
        return try modelContext.fetch(descriptor).map {
            OMEMOStoredPreKey(
                accountJID: $0.accountJID,
                keyID: UInt32($0.keyID),
                keyData: $0.keyData,
                isUsed: $0.isUsed
            )
        }
    }

    public func savePreKeys(_ preKeys: [OMEMOStoredPreKey]) throws {
        for preKey in preKeys {
            let record = OMEMOPreKeyRecord(
                id: UUID(),
                accountJID: preKey.accountJID,
                keyID: Int64(preKey.keyID),
                keyData: preKey.keyData,
                isUsed: preKey.isUsed
            )
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    public func consumePreKey(id: UInt32, accountJID: String) throws {
        let keyID = Int64(id)
        var descriptor = FetchDescriptor<OMEMOPreKeyRecord>(
            predicate: #Predicate { $0.accountJID == accountJID && $0.keyID == keyID }
        )
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            record.isUsed = true
            try modelContext.save()
        }
    }

    // MARK: - Signed Pre-Key

    public func loadSignedPreKey(for accountJID: String) throws -> OMEMOStoredSignedPreKey? {
        var descriptor = FetchDescriptor<OMEMOSignedPreKeyRecord>(
            predicate: #Predicate { $0.accountJID == accountJID }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return nil }
        return OMEMOStoredSignedPreKey(
            accountJID: record.accountJID,
            keyID: UInt32(record.keyID),
            keyData: record.keyData,
            signature: record.signature,
            timestamp: record.timestamp
        )
    }

    public func saveSignedPreKey(_ key: OMEMOStoredSignedPreKey) throws {
        let accountJID = key.accountJID
        var descriptor = FetchDescriptor<OMEMOSignedPreKeyRecord>(
            predicate: #Predicate { $0.accountJID == accountJID }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.keyID = Int64(key.keyID)
            existing.keyData = key.keyData
            existing.signature = key.signature
            existing.timestamp = key.timestamp
        } else {
            let record = OMEMOSignedPreKeyRecord(
                id: UUID(),
                accountJID: key.accountJID,
                keyID: Int64(key.keyID),
                keyData: key.keyData,
                signature: key.signature,
                timestamp: key.timestamp
            )
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    // MARK: - Sessions

    public func loadSessions(for accountJID: String) throws -> [OMEMOStoredSession] {
        let descriptor = FetchDescriptor<OMEMOSessionRecord>(
            predicate: #Predicate { $0.accountJID == accountJID }
        )
        return try modelContext.fetch(descriptor).map {
            OMEMOStoredSession(
                accountJID: $0.accountJID,
                peerJID: $0.peerJID,
                peerDeviceID: UInt32($0.peerDeviceID),
                sessionData: $0.sessionData,
                associatedData: $0.associatedData
            )
        }
    }

    public func saveSession(_ session: OMEMOStoredSession) throws {
        let accountJID = session.accountJID
        let peerJID = session.peerJID
        let peerDeviceID = Int64(session.peerDeviceID)
        var descriptor = FetchDescriptor<OMEMOSessionRecord>(
            predicate: #Predicate {
                $0.accountJID == accountJID && $0.peerJID == peerJID && $0.peerDeviceID == peerDeviceID
            }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.sessionData = session.sessionData
            existing.associatedData = session.associatedData
            existing.updatedAt = Date()
        } else {
            let record = OMEMOSessionRecord(
                id: UUID(),
                accountJID: session.accountJID,
                peerJID: session.peerJID,
                peerDeviceID: peerDeviceID,
                sessionData: session.sessionData,
                associatedData: session.associatedData
            )
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    // periphery:ignore - protocol requirement
    public func deleteSession(accountJID: String, peerJID: String, deviceID: UInt32) throws {
        let peerDeviceID = Int64(deviceID)
        let descriptor = FetchDescriptor<OMEMOSessionRecord>(
            predicate: #Predicate {
                $0.accountJID == accountJID && $0.peerJID == peerJID && $0.peerDeviceID == peerDeviceID
            }
        )
        for record in try modelContext.fetch(descriptor) {
            modelContext.delete(record)
        }
        try modelContext.save()
    }

    // MARK: - Trust

    public func saveTrust(_ trust: OMEMOTrust) throws {
        let accountJID = trust.accountJID
        let peerJID = trust.peerJID
        let deviceID = Int64(trust.deviceID)
        var descriptor = FetchDescriptor<OMEMOTrustRecord>(
            predicate: #Predicate {
                $0.accountJID == accountJID && $0.peerJID == peerJID && $0.deviceID == deviceID
            }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.fingerprint = trust.fingerprint
            existing.trustLevel = trust.trustLevel.rawValue
        } else {
            let record = OMEMOTrustRecord(
                id: UUID(),
                accountJID: trust.accountJID,
                peerJID: trust.peerJID,
                deviceID: deviceID,
                fingerprint: trust.fingerprint,
                trustLevel: trust.trustLevel.rawValue
            )
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    public func loadTrust(accountJID: String, peerJID: String, deviceID: UInt32) throws -> OMEMOTrust? {
        let deviceIDInt = Int64(deviceID)
        var descriptor = FetchDescriptor<OMEMOTrustRecord>(
            predicate: #Predicate {
                $0.accountJID == accountJID && $0.peerJID == peerJID && $0.deviceID == deviceIDInt
            }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return nil }
        return OMEMOTrust(
            accountJID: record.accountJID,
            peerJID: record.peerJID,
            deviceID: UInt32(record.deviceID),
            fingerprint: record.fingerprint,
            trustLevel: OMEMOTrustLevel(rawValue: record.trustLevel) ?? .undecided
        )
    }

    public func loadAllTrustedDevices(for peerJID: String, accountJID: String) throws -> [OMEMOTrust] {
        let descriptor = FetchDescriptor<OMEMOTrustRecord>(
            predicate: #Predicate { $0.accountJID == accountJID && $0.peerJID == peerJID }
        )
        return try modelContext.fetch(descriptor).map {
            OMEMOTrust(
                accountJID: $0.accountJID,
                peerJID: $0.peerJID,
                deviceID: UInt32($0.deviceID),
                fingerprint: $0.fingerprint,
                trustLevel: OMEMOTrustLevel(rawValue: $0.trustLevel) ?? .undecided
            )
        }
    }
}
