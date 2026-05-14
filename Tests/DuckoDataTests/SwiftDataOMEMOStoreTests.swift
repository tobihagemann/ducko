import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoData

/// Round-trip tests for the SwiftData persistence side of the new
/// seen-device classification cache and the orphan trust/session delete
/// methods added for the emergency-retract path. Lives in DuckoDataTests
/// because the `@Model` lives in DuckoData and DuckoCoreTests cannot
/// import DuckoData (module boundary rule).
struct SwiftDataOMEMOStoreTests {
    private func makeStore() throws -> SwiftDataOMEMOStore {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        return SwiftDataOMEMOStore(modelContainer: container)
    }

    @Test
    func `upsert and load round-trip preserves every field`() async throws {
        let store = try makeStore()
        let accountJID = "alice@example.com"
        let row = OMEMOStoredSeenDevice(
            accountJID: accountJID,
            deviceID: 4242,
            classification: "stale",
            staleStreak: 2,
            hasObservedHealthy: true
        )
        try await store.upsertSeenDevices([row], for: accountJID)

        let loaded = try await store.loadSeenDevices(for: accountJID)
        let read = try #require(loaded.first)
        #expect(read.deviceID == 4242)
        #expect(read.classification == "stale")
        #expect(read.staleStreak == 2)
        #expect(read.hasObservedHealthy == true)
    }

    @Test
    func `upsert updates existing row in place`() async throws {
        let store = try makeStore()
        let accountJID = "alice@example.com"
        let original = OMEMOStoredSeenDevice(
            accountJID: accountJID, deviceID: 1,
            classification: "healthy", staleStreak: 0, hasObservedHealthy: true
        )
        let updated = OMEMOStoredSeenDevice(
            accountJID: accountJID, deviceID: 1,
            classification: "stale", staleStreak: 1, hasObservedHealthy: true
        )
        try await store.upsertSeenDevices([original], for: accountJID)
        try await store.upsertSeenDevices([updated], for: accountJID)

        let loaded = try await store.loadSeenDevices(for: accountJID)
        #expect(loaded.count == 1)
        #expect(loaded.first?.classification == "stale")
        #expect(loaded.first?.staleStreak == 1)
    }

    @Test
    func `replace deletes rows absent from the new set`() async throws {
        let store = try makeStore()
        let accountJID = "alice@example.com"
        try await store.upsertSeenDevices(
            [
                OMEMOStoredSeenDevice(accountJID: accountJID, deviceID: 1, classification: "healthy", staleStreak: 0, hasObservedHealthy: true),
                OMEMOStoredSeenDevice(accountJID: accountJID, deviceID: 2, classification: "stale", staleStreak: 1, hasObservedHealthy: true)
            ],
            for: accountJID
        )

        try await store.replaceSeenDevices(
            [OMEMOStoredSeenDevice(accountJID: accountJID, deviceID: 9, classification: "healthy", staleStreak: 0, hasObservedHealthy: true)],
            for: accountJID
        )

        let loaded = try await store.loadSeenDevices(for: accountJID)
        #expect(loaded.count == 1)
        #expect(loaded.first?.deviceID == 9)
    }

    @Test
    func `purge clears one account leaves others intact`() async throws {
        let store = try makeStore()
        let acct1 = "alice@example.com"
        let acct2 = "bob@example.com"

        try await store.upsertSeenDevices(
            [OMEMOStoredSeenDevice(accountJID: acct1, deviceID: 1, classification: "healthy", staleStreak: 0, hasObservedHealthy: true)],
            for: acct1
        )
        try await store.upsertSeenDevices(
            [OMEMOStoredSeenDevice(accountJID: acct2, deviceID: 1, classification: "healthy", staleStreak: 0, hasObservedHealthy: true)],
            for: acct2
        )

        try await store.purgeSeenDevices(for: acct1)

        #expect(try await store.loadSeenDevices(for: acct1).isEmpty)
        #expect(try await store.loadSeenDevices(for: acct2).count == 1)
    }

    @Test
    func `deleteTrust removes only the targeted row`() async throws {
        let store = try makeStore()
        let accountJID = "alice@example.com"
        let peerJID = "bob@example.com"

        try await store.saveTrust(OMEMOTrust(
            accountJID: accountJID, peerJID: peerJID,
            deviceID: 1, fingerprint: "f1", trustLevel: .trusted
        ))
        try await store.saveTrust(OMEMOTrust(
            accountJID: accountJID, peerJID: peerJID,
            deviceID: 2, fingerprint: "f2", trustLevel: .trusted
        ))

        try await store.deleteTrust(accountJID: accountJID, peerJID: peerJID, deviceID: 1)

        let remaining = try await store.loadAllDevices(for: peerJID, accountJID: accountJID)
        #expect(remaining.count == 1)
        #expect(remaining.first?.deviceID == 2)
    }

    @Test
    func `deleteSession removes only the targeted row`() async throws {
        let store = try makeStore()
        let accountJID = "alice@example.com"
        let peerJID = "bob@example.com"

        try await store.saveSession(OMEMOStoredSession(
            accountJID: accountJID, peerJID: peerJID, peerDeviceID: 1,
            sessionData: Data([0x01]), associatedData: Data([0x02])
        ))
        try await store.saveSession(OMEMOStoredSession(
            accountJID: accountJID, peerJID: peerJID, peerDeviceID: 2,
            sessionData: Data([0x03]), associatedData: Data([0x04])
        ))

        try await store.deleteSession(accountJID: accountJID, peerJID: peerJID, peerDeviceID: 1)

        let remaining = try await store.loadSessions(for: accountJID)
        #expect(remaining.count == 1)
        #expect(remaining.first?.peerDeviceID == 2)
    }
}
