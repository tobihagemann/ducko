import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// MARK: - Helpers

private let testAccountJID = BareJID(localPart: "alice", domainPart: "example.com")!

@MainActor
private func makeOMEMOService(store: MockOMEMOStore) -> OMEMOService {
    OMEMOService(omemoStore: store)
}

private func makeIdentityData(deviceID: UInt32) -> OMEMOModule.OMEMOIdentityData {
    OMEMOModule.OMEMOIdentityData(
        deviceID: deviceID,
        identityKeyRaw: Array(repeating: 0xA1, count: 32),
        signedPreKeyID: 7,
        signedPreKeyRaw: Array(repeating: 0xB2, count: 32),
        signedPreKeySignature: Array(repeating: 0xC3, count: 64),
        preKeys: [
            OMEMOModule.OMEMOIdentityData.PreKeyData(
                keyID: 1, keyRaw: Array(repeating: 0xD4, count: 32)
            )
        ]
    )
}

private struct StubOMEMOIdentityProvider: OMEMOIdentityProviding {
    let identity: OMEMOModule.OMEMOIdentityData?
    let consumed: Set<UInt32>

    var ownIdentityData: OMEMOModule.OMEMOIdentityData? {
        identity
    }

    func consumedPreKeyIDs() -> Set<UInt32> {
        consumed
    }
}

// MARK: - Tests

enum OMEMOServiceTests {
    struct HandleConnectedFirstTimePersistence {
        @Test
        @MainActor
        func `returns early when identity already persisted`() async {
            let store = MockOMEMOStore()
            let accountJID = testAccountJID.description
            let identityData = makeIdentityData(deviceID: 4242)
            await store.seedFromIdentityData(identityData, accountJID: accountJID)

            let service = makeOMEMOService(store: store)
            let stub = StubOMEMOIdentityProvider(identity: identityData, consumed: [])

            await service.handleConnectedFirstTimePersistence(
                provider: stub,
                accountJID: accountJID,
                pollTimeout: .milliseconds(100)
            )

            #expect(await store.saveIdentityCalls == 0)
            #expect(await store.savePreKeysCalls == 0)
            #expect(await store.saveSignedPreKeyCalls == 0)
        }

        @Test
        @MainActor
        func `persists identity from provider when store empty`() async throws {
            let store = MockOMEMOStore()
            let accountJID = testAccountJID.description
            let identityData = makeIdentityData(deviceID: 4242)
            let stub = StubOMEMOIdentityProvider(identity: identityData, consumed: [])
            let service = makeOMEMOService(store: store)

            await service.handleConnectedFirstTimePersistence(
                provider: stub,
                accountJID: accountJID,
                pollTimeout: .seconds(2)
            )

            #expect(await store.saveIdentityCalls == 1)
            #expect(await store.savePreKeysCalls == 1)
            #expect(await store.saveSignedPreKeyCalls == 1)

            let storedIdentity = try #require(await store.loadIdentity(for: accountJID))
            #expect(storedIdentity.deviceID == 4242)
            #expect(storedIdentity.identityKeyData == Data(identityData.identityKeyRaw))

            let storedPreKeys = try await store.loadPreKeys(for: accountJID)
            #expect(storedPreKeys.count == 1)
            #expect(storedPreKeys[0].keyID == 1)
            #expect(storedPreKeys[0].keyData == Data(identityData.preKeys[0].keyRaw))

            let storedSPK = try #require(await store.loadSignedPreKey(for: accountJID))
            #expect(storedSPK.keyID == identityData.signedPreKeyID)
            #expect(storedSPK.keyData == Data(identityData.signedPreKeyRaw))
            #expect(storedSPK.signature == Data(identityData.signedPreKeySignature))
        }

        @Test
        @MainActor
        func `marks consumed pre-keys as used`() async throws {
            let store = MockOMEMOStore()
            let accountJID = testAccountJID.description

            // Pre-seed identity (so the persistence branch early-returns) plus
            // three fresh pre-keys to consume against.
            await store.seedFromIdentityData(makeIdentityData(deviceID: 4242), accountJID: accountJID)
            await store.seedPreKeys([2, 3].map {
                OMEMOStoredPreKey(
                    accountJID: accountJID, keyID: $0,
                    keyData: Data(Array(repeating: UInt8($0), count: 32)),
                    isUsed: false
                )
            })

            let service = makeOMEMOService(store: store)
            let stub = StubOMEMOIdentityProvider(
                identity: makeIdentityData(deviceID: 4242),
                consumed: [1, 3]
            )

            await service.handleConnectedFirstTimePersistence(
                provider: stub,
                accountJID: accountJID,
                pollTimeout: .milliseconds(100)
            )

            let preKeys = try await store.loadPreKeys(for: accountJID)
            let used = Set(preKeys.filter(\.isUsed).map(\.keyID))
            let unused = Set(preKeys.filter { !$0.isUsed }.map(\.keyID))
            #expect(used == [1, 3])
            #expect(unused == [2])
        }

        @Test
        @MainActor
        func `skips persistence when identity never readies`() async {
            let store = MockOMEMOStore()
            let accountJID = testAccountJID.description
            let stub = StubOMEMOIdentityProvider(identity: nil, consumed: [])
            let service = makeOMEMOService(store: store)

            let start = ContinuousClock.now
            await service.handleConnectedFirstTimePersistence(
                provider: stub,
                accountJID: accountJID,
                pollTimeout: .milliseconds(100)
            )
            let elapsed = start.duration(to: ContinuousClock.now)

            #expect(await store.saveIdentityCalls == 0)
            #expect(await store.savePreKeysCalls == 0)
            #expect(await store.saveSignedPreKeyCalls == 0)
            // Polling exhausts at ~100 ms; allow generous slack for CI variance.
            #expect(elapsed < .milliseconds(500))
        }
    }

    /// Pins `MockOMEMOStore`'s upsert behavior so future mock-only edits can't
    /// silently drift back to append-on-write.
    struct MockStoreSemantics {
        @Test
        @MainActor
        func `saveSession upserts by peer JID and device ID`() async throws {
            let store = MockOMEMOStore()
            let accountJID = testAccountJID.description
            let peerJID = "peer@example.com"
            let deviceID: UInt32 = 42

            let original = OMEMOStoredSession(
                accountJID: accountJID, peerJID: peerJID, peerDeviceID: deviceID,
                sessionData: Data([0xAA]), associatedData: Data([0xBB])
            )
            let replacement = OMEMOStoredSession(
                accountJID: accountJID, peerJID: peerJID, peerDeviceID: deviceID,
                sessionData: Data([0xCC]), associatedData: Data([0xDD])
            )
            try await store.saveSession(original)
            try await store.saveSession(replacement)

            let sessions = try await store.loadSessions(for: accountJID)
            #expect(sessions.count == 1)
            #expect(sessions.first?.sessionData == Data([0xCC]))
            #expect(sessions.first?.associatedData == Data([0xDD]))
        }

        @Test
        @MainActor
        func `saveTrust upserts by peer JID and device ID`() async throws {
            let store = MockOMEMOStore()
            let accountJID = testAccountJID.description
            let peerJID = "peer@example.com"
            let deviceID: UInt32 = 42

            try await store.saveTrust(OMEMOTrust(
                accountJID: accountJID, peerJID: peerJID,
                deviceID: deviceID, fingerprint: "", trustLevel: .undecided
            ))
            try await store.saveTrust(OMEMOTrust(
                accountJID: accountJID, peerJID: peerJID,
                deviceID: deviceID, fingerprint: "abcd", trustLevel: .verified
            ))

            let devices = try await store.loadAllDevices(for: peerJID, accountJID: accountJID)
            #expect(devices.count == 1)
            #expect(devices.first?.fingerprint == "abcd")
            #expect(devices.first?.trustLevel == .verified)
        }
    }
}
