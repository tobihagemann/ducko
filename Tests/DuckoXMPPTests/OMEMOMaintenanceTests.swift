import DuckoTestSupport
import Testing
@testable import DuckoXMPP

private enum MaintenanceFailure: Error { case publication, orphanPurge }

private actor MaintenanceRecords: SeenDeviceClassificationProviding, EmergencyRetractGuarding, OrphanDeviceRecordPurging {
    private(set) var records: [UInt32: SeenDeviceRecord] = [2: SeenDeviceRecord(deviceID: 2, lastClassification: .healthy, staleStreak: 0, hasObservedHealthy: true)]
    private(set) var actions: [String] = []
    private(set) var held = false
    let failure: MaintenanceFailure?

    init(failure: MaintenanceFailure? = nil) {
        self.failure = failure
    }

    func record(_ action: String) {
        actions.append(action)
    }

    func loadSeenDevices(accountID: String) -> [UInt32: SeenDeviceRecord] {
        records
    }

    func mergeSeenDevices(_ updates: [UInt32: SeenDeviceRecord], accountID: String) {
        records.merge(updates) { _, new in new }
    }

    func clearSeenDevicesAbsent(from currentDeviceIDs: Set<UInt32>, accountID: String) {
        records = records.filter { currentDeviceIDs.contains($0.key) }
    }

    func replaceSeenDevices(_ records: [UInt32: SeenDeviceRecord], accountID: String) {
        actions.append("replace")
        self.records = records
    }

    func tryClaimInFlight(accountID: String) -> Bool {
        actions.append("claim")
        guard !held else { return false }
        held = true
        return true
    }

    func releaseInFlight(accountID: String) {
        actions.append("release")
        held = false
    }

    func publish(_ devices: [UInt32]) throws {
        #expect(devices == [1])
        actions.append("publish")
        if failure == .publication { throw MaintenanceFailure.publication }
    }

    func purgeOrphanDeviceRecords(deviceIDs: [UInt32], accountID: String) throws {
        #expect(deviceIDs == Array(UInt32(2) ... 66))
        actions.append("purge")
        if failure == .orphanPurge { throw MaintenanceFailure.orphanPurge }
    }
}

private func maintenance(
    records: MaintenanceRecords,
    confirmation: @escaping EmergencyRetractConfirmation = { _, _ in true }
) -> OMEMOMaintenance {
    OMEMOMaintenance(
        context: .init(provider: records, accountID: "test-account", retractGuard: records, retractConfirmation: confirmation, orphanPurger: records),
        operations: .init(
            fetchBundlePayload: { _ in Issue.record("Over-cap maintenance must not probe bundles"); return nil },
            isValidBundle: { _, _ in false },
            publishDeviceList: { try await records.publish($0) },
            retractBundle: { await records.record("retract:\($0)") },
            cacheDeviceList: { #expect($0 == [1]) }
        )
    )
}

struct OMEMOMaintenanceTests {
    private let devices = Array(UInt32(1) ... 66)

    @Test
    func `publication failure releases guard without retracting or replacing history`() async throws {
        let records = MaintenanceRecords(failure: .publication)
        await #expect(throws: MaintenanceFailure.publication) {
            _ = try await maintenance(records: records).pruneStaleBundles(ownDeviceID: 1, ownDeviceList: devices)
        }
        #expect(await records.actions == ["claim", "publish", "release"])
        #expect(await records.records.keys.sorted() == [2])
        #expect(await records.held == false)
    }

    @Test
    func `orphan failure propagates after publish and retraction while retaining history`() async throws {
        let records = MaintenanceRecords(failure: .orphanPurge)
        await #expect(throws: MaintenanceFailure.orphanPurge) {
            _ = try await maintenance(records: records).pruneStaleBundles(ownDeviceID: 1, ownDeviceList: devices)
        }
        #expect(await records.actions == ["claim", "publish"] + (2 ... 66).map { "retract:\($0)" } + ["purge", "release"])
        #expect(await records.records.keys.sorted() == [2])
        #expect(await records.held == false)
    }

    @Test
    func `successful emergency maintenance publishes before retracting then purges and replaces history`() async throws {
        let records = MaintenanceRecords()
        let result = try await maintenance(records: records).pruneStaleBundles(ownDeviceID: 1, ownDeviceList: devices)
        #expect(result == [1])
        #expect(await records.actions == ["claim", "publish"] + (2 ... 66).map { "retract:\($0)" } + ["purge", "replace", "release"])
        #expect(await records.records.keys.sorted() == [1])
        #expect(await records.held == false)
    }

    @Test
    func `denied confirmation releases guard without publication`() async throws {
        let records = MaintenanceRecords()
        let result = try await maintenance(records: records, confirmation: { _, _ in false }).pruneStaleBundles(ownDeviceID: 1, ownDeviceList: devices)
        #expect(result == devices)
        #expect(await records.actions == ["claim", "release"])
        #expect(await records.held == false)
    }

    @Test
    func `recreated maintenance shares in flight guard and cancellation releases it before publication`() async throws {
        let records = MaintenanceRecords()
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        let first = maintenance(records: records, confirmation: { _, _ in
            await entered.signal()
            await release.wait()
            return true
        })
        let operation = Task { try await first.pruneStaleBundles(ownDeviceID: 1, ownDeviceList: devices) }
        defer { operation.cancel(); Task { await release.signal() } }
        let arrived = try await boundedOutcome { await entered.wait() }
        try #require(arrived != nil)
        let second = maintenance(records: records, confirmation: { _, _ in Issue.record("A second owner must not ask again"); return true })
        #expect(try await second.pruneStaleBundles(ownDeviceID: 1, ownDeviceList: devices) == devices)
        operation.cancel()
        await release.signal()
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        #expect(await records.actions == ["claim", "claim", "release"])
        #expect(await records.held == false)
        #expect(await records.records.keys.sorted() == [2])
    }
}
