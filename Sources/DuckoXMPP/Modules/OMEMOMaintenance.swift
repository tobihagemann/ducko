import Logging

private let log = Logger(label: "im.ducko.xmpp.omemo")

/// Own-device maintenance runs in its caller's task using reconnect-surviving Core collaborators.
struct OMEMOMaintenance {
    struct Operations {
        let fetchBundlePayload: @Sendable (UInt32) async throws -> XMLElement?
        let isValidBundle: @Sendable (XMLElement, UInt32) -> Bool
        let publishDeviceList: @Sendable ([UInt32]) async throws -> Void
        let retractBundle: @Sendable (UInt32) async throws -> Void
        let cacheDeviceList: @Sendable ([UInt32]) -> Void
    }

    let context: PruneContext
    let operations: Operations

    // MARK: - Stale Bundle Pruning

    /// Cap on peer-device probes per prune. A hostile PEP server could return an arbitrarily large own-device list;
    /// without a cap, every reconnect issues thousands of IQs. 64 is generous for legitimate users.
    private static let pruneProbeCap = 64

    /// Two-stale gate threshold: requires a prior `.healthy` then two consecutive `.stale` observations before auto-retract.
    /// Defends against a hostile own-server answering `item-not-found` for a real sibling's bundle on a single reconnect.
    private static let staleRetractStreakThreshold = 2

    /// Probes each peer-listed bundle, classifies the response, and auto-retracts orphans when the per-device lineage
    /// (kept on `OMEMOService` across reconnects) shows `healthy → stale → stale`. First-observation never retracts.
    ///
    /// Over-cap path (`peerDeviceIDs.count > pruneProbeCap`): invokes the emergency-retract closure; on confirm,
    /// publishes a singleton devicelist first (rollback-safe), retracts every non-own bundle, purges orphans, and
    /// resets the cache to a singleton baseline. Throws only when the re-publish fails.
    struct PruneContext {
        let provider: (any SeenDeviceClassificationProviding)?
        let accountID: String?
        let retractGuard: (any EmergencyRetractGuarding)?
        let retractConfirmation: EmergencyRetractConfirmation?
        let orphanPurger: (any OrphanDeviceRecordPurging)?
    }

    func pruneStaleBundles(
        ownDeviceID: UInt32, ownDeviceList: [UInt32]
    ) async throws -> [UInt32] {
        let peerDeviceIDs = ownDeviceList.filter { $0 != ownDeviceID }

        // Empty peer-list path: drop any leftover sibling records the cache
        // still carries so the next list-regrowth sees the new IDs as
        // truly unseen. Membership is decoupled from classification.
        guard !peerDeviceIDs.isEmpty else {
            if let provider = context.provider, let accountID = context.accountID {
                await provider.clearSeenDevicesAbsent(from: Set([ownDeviceID]), accountID: accountID)
            }
            return ownDeviceList
        }

        if peerDeviceIDs.count > Self.pruneProbeCap {
            return try await handleOverCapDeviceList(
                ownDeviceID: ownDeviceID, ownDeviceList: ownDeviceList,
                peerDeviceCount: peerDeviceIDs.count, context: context
            )
        }

        let classifications = await classifyBundleProbes(deviceIDs: peerDeviceIDs)
        let previousRecords = await loadPreviousSeenRecords(context: context)
        let (updatedRecords, retractIDs) = computeProbeOutcome(
            classifications: classifications, previousRecords: previousRecords
        )

        if !retractIDs.isEmpty {
            return try await retractAndRePublish(
                retractIDs: retractIDs,
                ownDeviceList: ownDeviceList,
                updatedRecords: updatedRecords,
                provider: context.provider,
                accountID: context.accountID
            )
        }

        if let provider = context.provider, let accountID = context.accountID {
            await provider.mergeSeenDevices(updatedRecords, accountID: accountID)
            // Drop records for IDs that vanished from PEP (legitimate sibling
            // retraction) so a peer's "old healthy survives after
            // disappearance" attack can't bypass the gate on the next regrow.
            await provider.clearSeenDevicesAbsent(from: Set(ownDeviceList), accountID: accountID)
        }
        return ownDeviceList
    }

    /// Loads the previous classification cache once per prune cycle. Falls
    /// back to an empty map when no provider is wired.
    private func loadPreviousSeenRecords(context: PruneContext) async -> [UInt32: SeenDeviceRecord] {
        guard let provider = context.provider, let accountID = context.accountID else { return [:] }
        return await provider.loadSeenDevices(accountID: accountID)
    }

    /// Folds the per-device classification results into updated records and the retract list.
    private func computeProbeOutcome(
        classifications: [(id: UInt32, classification: BundleClassification)],
        previousRecords: [UInt32: SeenDeviceRecord]
    ) -> (updatedRecords: [UInt32: SeenDeviceRecord], retractIDs: [UInt32]) {
        var updatedRecords: [UInt32: SeenDeviceRecord] = [:]
        var retractIDs: [UInt32] = []
        for (deviceID, classification) in classifications.map({ ($0.id, $0.classification) }) {
            let outcome = nextSeenDeviceRecord(
                deviceID: deviceID,
                classification: classification,
                previous: previousRecords[deviceID]
            )
            updatedRecords[deviceID] = outcome.record
            if outcome.shouldRetract {
                retractIDs.append(deviceID)
            }
        }
        return (updatedRecords, retractIDs)
    }

    /// Resource-exhaustion guard: an over-cap list is adversary-provided
    /// and untrustworthy. Preserve the cache state and let the emergency-
    /// retract closure (when configured) prompt the user to recover.
    private func handleOverCapDeviceList(
        ownDeviceID: UInt32, ownDeviceList: [UInt32],
        peerDeviceCount: Int, context: PruneContext
    ) async throws -> [UInt32] {
        log.warning("OMEMO device list has \(peerDeviceCount) peer devices, exceeding probe cap; skipping prune")
        guard let accountID = context.accountID,
              let retractGuard = context.retractGuard,
              let retractConfirmation = context.retractConfirmation
        else { return ownDeviceList }
        let claimed = await retractGuard.tryClaimInFlight(accountID: accountID)
        guard claimed else { return ownDeviceList }
        // `defer` cannot await; release after the publish/retract/cleanup
        // path completes so a second prune during this window sees the
        // in-flight flag and bails.
        do {
            try Task.checkCancellation()
            let confirmed = await retractConfirmation(peerDeviceCount, ownDeviceID)
            try Task.checkCancellation()
            guard confirmed else {
                await retractGuard.releaseInFlight(accountID: accountID)
                return ownDeviceList
            }
            let result = try await performEmergencyRetract(
                ownDeviceID: ownDeviceID, ownDeviceList: ownDeviceList,
                provider: context.provider, accountID: accountID,
                orphanPurger: context.orphanPurger
            )
            await retractGuard.releaseInFlight(accountID: accountID)
            return result
        } catch {
            await retractGuard.releaseInFlight(accountID: accountID)
            throw error
        }
    }

    private struct SeenDeviceProgress {
        let record: SeenDeviceRecord
        let shouldRetract: Bool
    }

    /// Folds a single classification result into the per-device seen-device record.
    private func nextSeenDeviceRecord(
        deviceID: UInt32,
        classification: BundleClassification,
        previous: SeenDeviceRecord?
    ) -> SeenDeviceProgress {
        switch classification {
        case .healthy:
            return SeenDeviceProgress(
                record: SeenDeviceRecord(
                    deviceID: deviceID, lastClassification: .healthy,
                    staleStreak: 0, hasObservedHealthy: true
                ),
                shouldRetract: false
            )
        case .transient:
            // Preserve the previous record verbatim to avoid penalizing
            // intermittent network failures. First observation as transient
            // still records the lineage so a future healthy can flip
            // `hasObservedHealthy`.
            if let previous {
                return SeenDeviceProgress(record: previous, shouldRetract: false)
            }
            log.info("OMEMO stale bundle first observation classified as transient")
            log.debug("OMEMO stale bundle device \(deviceID) classified as transient (no prior record)")
            return SeenDeviceProgress(
                record: SeenDeviceRecord(
                    deviceID: deviceID, lastClassification: .transient,
                    staleStreak: 0, hasObservedHealthy: false
                ),
                shouldRetract: false
            )
        case .stale:
            return staleSeenDeviceProgress(deviceID: deviceID, previous: previous)
        }
    }

    /// Stale-branch of `nextSeenDeviceRecord`: increments the streak, preserves `hasObservedHealthy`, and fires the two-stale gate when both pass.
    private func staleSeenDeviceProgress(
        deviceID: UInt32,
        previous: SeenDeviceRecord?
    ) -> SeenDeviceProgress {
        let staleStreak = (previous?.staleStreak ?? 0) + 1
        let hasObservedHealthy = previous?.hasObservedHealthy ?? false
        let record = SeenDeviceRecord(
            deviceID: deviceID, lastClassification: .stale,
            staleStreak: staleStreak, hasObservedHealthy: hasObservedHealthy
        )
        let shouldRetract = hasObservedHealthy && staleStreak >= Self.staleRetractStreakThreshold
        logStaleObservation(
            deviceID: deviceID, staleStreak: staleStreak,
            hasObservedHealthy: hasObservedHealthy,
            previous: previous, willRetract: shouldRetract
        )
        return SeenDeviceProgress(record: record, shouldRetract: shouldRetract)
    }

    /// Emits the operator-facing log line for a single stale observation.
    /// Privacy policy: counts and outcomes go at `.info`/`.warning`;
    /// the device ID is logged at `.debug` only.
    private func logStaleObservation(
        deviceID: UInt32,
        staleStreak: Int,
        hasObservedHealthy: Bool,
        previous: SeenDeviceRecord?,
        willRetract: Bool
    ) {
        if willRetract {
            log.warning("OMEMO auto-retracting confirmed-stale bundle (streak \(staleStreak))")
            log.debug("OMEMO auto-retracting confirmed-stale bundle device \(deviceID) staleStreak=\(staleStreak)")
        } else if hasObservedHealthy {
            log.info("OMEMO stale bundle confirmed once; will auto-retract on next reconnect if still missing")
            log.debug("OMEMO stale bundle device \(deviceID) staleStreak=\(staleStreak)")
        } else if previous == nil {
            log.info("OMEMO stale bundle first observation; no prior healthy, not auto-retracting")
            log.debug("OMEMO stale bundle first observation device \(deviceID)")
        } else {
            log.info("OMEMO stale bundle observed \(staleStreak) times without prior healthy; not auto-retracting")
            log.debug("OMEMO stale bundle device \(deviceID) staleStreak=\(staleStreak) no prior healthy")
        }
    }

    /// Singleton-publish → bundle-retract → orphan-purge → cache-reset. Publishes first so a publish failure leaves
    /// PEP untouched (mirrors `retractAndRePublish`'s ordering).
    private func performEmergencyRetract(
        ownDeviceID: UInt32,
        ownDeviceList: [UInt32],
        provider: (any SeenDeviceClassificationProviding)?,
        accountID: String,
        orphanPurger: (any OrphanDeviceRecordPurging)?
    ) async throws -> [UInt32] {
        let trimmedList = [ownDeviceID]
        try await operations.publishDeviceList(trimmedList)

        let retractIDs = ownDeviceList.filter { $0 != ownDeviceID }
        for id in retractIDs {
            do {
                try await operations.retractBundle(id)
            } catch let stanzaError as XMPPStanzaError {
                log.warning("OMEMO emergency-retract bundle failed: \(stanzaError.condition.rawValue)")
                log.debug("OMEMO emergency-retract bundle failed for device \(id): \(stanzaError.condition.rawValue)")
            } catch {
                log.warning("OMEMO emergency-retract bundle failed")
                log.debug("OMEMO emergency-retract bundle failed for device \(id): \(error)")
            }
        }

        // Orphan trust/session cleanup is fail-loud: if it fails the user
        // sees the dialog state didn't fully apply. Bookkeeping rows for
        // retracted own-deviceIDs would otherwise be targetable from a
        // restored backup whose local bundles still cache them.
        if let orphanPurger {
            do {
                try await orphanPurger.purgeOrphanDeviceRecords(deviceIDs: retractIDs, accountID: accountID)
            } catch {
                log.warning("OMEMO emergency-retract orphan cleanup failed")
                log.debug("OMEMO emergency-retract orphan cleanup failed: \(error)")
                throw error
            }
        }

        operations.cacheDeviceList(trimmedList)
        if let provider {
            // `replace` (not `merge`) is critical — delta-merge would leave
            // old sibling rows in the cache and re-trigger the gate on the
            // next prune.
            await provider.replaceSeenDevices(
                [ownDeviceID: SeenDeviceRecord(
                    deviceID: ownDeviceID,
                    lastClassification: .healthy,
                    staleStreak: 0,
                    hasObservedHealthy: true
                )],
                accountID: accountID
            )
        }
        log.warning("OMEMO emergency-retract completed: trimmed to singleton, \(retractIDs.count) bundle(s) retracted")
        return trimmedList
    }

    /// Probes each peer-device bundle and classifies the response. Concurrency capped at 4 by chunking (`withTaskGroup` has no built-in limiter).
    private func classifyBundleProbes(
        deviceIDs: [UInt32]
    ) async -> [(id: UInt32, classification: BundleClassification)] {
        let chunkSize = 4
        var classifications: [(id: UInt32, classification: BundleClassification)] = []
        classifications.reserveCapacity(deviceIDs.count)
        for chunkStart in stride(from: 0, to: deviceIDs.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, deviceIDs.count)
            let chunk = deviceIDs[chunkStart ..< chunkEnd]
            let chunkResults = await withTaskGroup(
                of: (id: UInt32, classification: BundleClassification).self
            ) { group in
                for id in chunk {
                    group.addTask {
                        await probeBundle(deviceID: id)
                    }
                }
                var collected: [(id: UInt32, classification: BundleClassification)] = []
                for await pair in group {
                    collected.append(pair)
                }
                return collected
            }
            classifications.append(contentsOf: chunkResults)
        }
        return classifications
    }

    /// Classifies a peer-device bundle: `item-not-found` or payload-parse-failure → `.stale`; empty `<items/>` list →
    /// `.transient` (ambiguous, possibly a hostile server answering empty for a live bundle); healthy parse → `.healthy`.
    private func probeBundle(
        deviceID: UInt32
    ) async -> (id: UInt32, classification: BundleClassification) {
        do {
            guard let payload = try await operations.fetchBundlePayload(deviceID) else {
                return (id: deviceID, classification: .transient)
            }
            if !operations.isValidBundle(payload, deviceID) {
                return (id: deviceID, classification: .stale)
            }
            return (id: deviceID, classification: .healthy)
        } catch let stanzaError as XMPPStanzaError where stanzaError.condition == .itemNotFound {
            return (id: deviceID, classification: .stale)
        } catch let stanzaError as XMPPStanzaError {
            log.warning("OMEMO bundle probe failed: \(stanzaError.condition.rawValue)")
            log.debug("OMEMO bundle probe failed for device \(deviceID): \(stanzaError.condition.rawValue)")
            return (id: deviceID, classification: .transient)
        } catch {
            log.warning("OMEMO bundle probe failed")
            log.debug("OMEMO bundle probe failed for device \(deviceID): \(error)")
            return (id: deviceID, classification: .transient)
        }
    }

    /// Publishes the trimmed list FIRST so a retract failure leaves PEP no worse off — a `fetchBundle` on a still-orphan bundle is harmless once the list no longer names it.
    private func retractAndRePublish(
        retractIDs: [UInt32],
        ownDeviceList: [UInt32],
        updatedRecords: [UInt32: SeenDeviceRecord],
        provider: (any SeenDeviceClassificationProviding)?,
        accountID: String?
    ) async throws -> [UInt32] {
        let trimmedList = ownDeviceList.filter { !retractIDs.contains($0) }
        try await operations.publishDeviceList(trimmedList)
        for id in retractIDs {
            do {
                try await operations.retractBundle(id)
            } catch let stanzaError as XMPPStanzaError {
                log.warning("OMEMO bundle retract failed: \(stanzaError.condition.rawValue)")
                log.debug("OMEMO bundle retract failed for device \(id): \(stanzaError.condition.rawValue)")
            } catch {
                log.warning("OMEMO bundle retract failed")
                log.debug("OMEMO bundle retract failed for device \(id): \(error)")
            }
        }
        operations.cacheDeviceList(trimmedList)
        if let provider, let accountID {
            // Drop retracted IDs from the merge; `clearSeenDevicesAbsent` then deletes the corresponding store rows so the next prune sees a clean slate.
            var survivingUpdates = updatedRecords
            for id in retractIDs {
                survivingUpdates.removeValue(forKey: id)
            }
            await provider.mergeSeenDevices(survivingUpdates, accountID: accountID)
            await provider.clearSeenDevicesAbsent(from: Set(trimmedList), accountID: accountID)
        }
        log.info("OMEMO pruned \(retractIDs.count) stale bundle(s)")
        return trimmedList
    }
}
