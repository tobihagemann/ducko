import DuckoXMPP
import Foundation

@MainActor
final class RosterSynchronization {
    enum Failure: Error, LocalizedError {
        case ended, degraded, timedOut, invalidResponse

        var errorDescription: String? {
            switch self {
            case .ended: "The account disconnected before contacts finished syncing"
            case .degraded: "Contacts could not be synchronized. Reconnect to sync them"
            case .timedOut: "Contacts did not finish syncing in time"
            case .invalidResponse: "The server did not return a complete contact list"
            }
        }
    }

    private enum Phase {
        case awaitingBaseline
        case ready
        case recovering(String)
        case degraded
        case ended
    }

    private struct Readback {
        let continuation: CheckedContinuation<[Contact], any Error>
        let deadlineTask: Task<Void, Never>
        var requestTask: Task<Void, Never>?
    }

    private struct Command {
        let continuation: CheckedContinuation<RosterCommandOutcome, Never>
        let operation: RosterCommandOutcome.Operation
        let jid: String
        var subscription: RosterCommandOutcome.SubscriptionStatus
        let deadlineTask: Task<Void, Never>
        var task: Task<Void, Never>?
    }

    private var ownedTasks: [UUID: Task<Void, Never>] = [:]
    private var commands: [UUID: Command] = [:]
    let sessionID: UUID
    private let accountID: UUID
    private let store: any PersistenceStore
    private let client: XMPPClient
    private let publish: ([Contact]) -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void
    private var phase: Phase = .awaitingBaseline
    private var queue: [RosterUpdate] = []
    private var fenced: [RosterUpdate] = []
    private var lastReceipt: UInt64 = 0
    private var recoveryUsed = false
    private var baselineAdmitted = false
    private var worker: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var readbacks: [String: Readback] = [:]

    init(accountID: UUID, sessionID: UUID, store: any PersistenceStore, client: XMPPClient,
         sleep: @Sendable @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @Sendable @escaping () -> ContinuousClock.Instant = { .now },
         publish: @escaping ([Contact]) -> Void) {
        self.accountID = accountID
        self.sessionID = sessionID
        self.store = store
        self.client = client
        self.sleep = sleep
        self.now = now
        self.publish = publish
    }

    @discardableResult
    func receive(_ update: RosterUpdate) -> Task<Void, Never>? {
        guard update.receipt > lastReceipt else { return nil }
        lastReceipt = update.receipt
        switch phase {
        case .ended, .degraded: return nil
        case .awaitingBaseline:
            if case .delta = update.contents, !baselineAdmitted {
                fenced.append(update)
                return nil
            }
            if case .snapshot = update.contents { fenced.removeAll() }
            if update.origin == .initial { baselineAdmitted = true }
        case let .recovering(id):
            guard update.origin == .readback(id) || (baselineAdmitted && update.origin == .push) else {
                if case let .readback(requestID) = update.origin { resolve(requestID, result: .failure(Failure.degraded)) }
                return nil
            }
            if update.origin == .readback(id) { baselineAdmitted = true }
        case .ready: break
        }
        queue.append(update)
        startWorker()
        return worker
    }

    func resume() {
        guard case .awaitingBaseline = phase else { return }
        beginReconciliation()
    }

    func synchronize(within duration: Duration) async throws -> [Contact] {
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                switch phase {
                case .ended:
                    continuation.resume(throwing: Failure.ended)
                    return
                case .degraded:
                    continuation.resume(throwing: Failure.degraded)
                    return
                case .awaitingBaseline, .ready, .recovering: break
                }
                let timer = ownTask { [weak self, sleep] in
                    do { try await sleep(duration) } catch { return }
                    self?.resolve(id, result: .failure(Failure.timedOut))
                }
                readbacks[id] = Readback(continuation: continuation, deadlineTask: timer)
                if case .ready = phase { startReadback(id) }
            }
        } onCancel: {
            Task { @MainActor in self.resolve(id, result: .failure(CancellationError())) }
        }
    }

    func completeMutation(operation: RosterCommandOutcome.Operation, jid: BareJID, name: String?, groups: [String], module: RosterModule, acknowledgedAt: ContinuousClock.Instant = .now, within duration: Duration = .seconds(5)) async -> RosterCommandOutcome {
        let deadline = acknowledgedAt + duration
        let remaining = now().duration(to: deadline)
        guard remaining > .zero else {
            return RosterCommandOutcome(operation: operation, accountID: accountID, jid: jid.description, localStatus: .incomplete, subscriptionStatus: operation == .add ? .incomplete : .notRequested)
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timer = ownTask { [weak self, sleep] in
                    do { try await sleep(remaining) } catch { return }
                    self?.resolveCommand(id)
                }
                commands[id] = Command(continuation: continuation, operation: operation, jid: jid.description,
                                       subscription: operation == .add ? .incomplete : .notRequested, deadlineTask: timer)
                if Task.isCancelled {
                    resolveCommand(id)
                    return
                }
                switch phase {
                case .ended, .degraded:
                    resolveCommand(id)
                    return
                case .awaitingBaseline, .recovering, .ready: break
                }
                commands[id]?.task = ownTask { [weak self] in
                    guard let self else { return }
                    if operation == .add {
                        do {
                            try await module.subscribe(to: jid)
                            commands[id]?.subscription = .sent
                        } catch {}
                    }
                    guard commands[id] != nil, !Task.isCancelled else { return }
                    do {
                        let contacts = try await synchronize(within: max(.zero, now().duration(to: deadline)))
                        guard commands[id] != nil else { return }
                        let observed = contacts.first { $0.jid == jid }
                        let matches: Bool = switch operation {
                        case .remove: observed == nil
                        case .add: observed != nil && (name == nil || observed?.name == name) && Set(observed?.groups ?? []) == Set(groups)
                        }
                        resolveCommand(id, status: matches ? .synchronized : .different)
                    } catch {
                        resolveCommand(id)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.resolveCommand(id) }
        }
    }

    private func resolveCommand(_ id: UUID, status: RosterCommandOutcome.LocalStatus = .incomplete) {
        guard let command = commands.removeValue(forKey: id) else { return }
        command.deadlineTask.cancel()
        command.task?.cancel()
        command.continuation.resume(returning: RosterCommandOutcome(operation: command.operation, accountID: accountID, jid: command.jid, localStatus: status, subscriptionStatus: command.subscription))
    }

    private static func requestReadback(id: String, client: XMPPClient) async throws {
        guard let module = await client.module(ofType: RosterModule.self) else { throw Failure.invalidResponse }
        try Task.checkCancellation()
        _ = try await module.requestFullRoster(id: id)
    }

    private func startReadback(_ id: String) {
        guard readbacks[id]?.requestTask == nil else { return }
        readbacks[id]?.requestTask = ownTask { [weak self, client] in
            do {
                try await Self.requestReadback(id: id, client: client)
            } catch {
                self?.resolve(id, result: .failure(error))
            }
        }
    }

    private func resolve(_ id: String, result: Result<[Contact], any Error>) {
        guard let pending = readbacks.removeValue(forKey: id) else { return }
        pending.deadlineTask.cancel()
        pending.requestTask?.cancel()
        pending.continuation.resume(with: result)
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = ownTask { [weak self] in
            guard let self else { return }
            await drain()
            worker = nil
        }
    }

    private func drain() async {
        while !queue.isEmpty, !Task.isCancelled {
            let update = queue.removeFirst()
            if case .initialQueryFailed = update.contents {
                degrade()
                return
            }
            do {
                let contacts: [Contact]
                switch update.contents {
                case let .snapshot(items):
                    contacts = try await store.applyRosterMutation(RosterMutation(accountID: accountID, contents: .snapshot(items.map(RosterMutation.Item.init)), version: update.version))
                case let .delta(item):
                    contacts = try await store.applyRosterMutation(RosterMutation(accountID: accountID, contents: .delta(RosterMutation.Item(item)), version: update.version))
                case .cachedBaseline:
                    contacts = try await store.fetchContacts(for: accountID)
                case .initialQueryFailed: return
                }
                guard !Task.isCancelled else { return }
                switch phase {
                case .ended, .degraded: return
                case let .recovering(id):
                    guard update.origin == .readback(id) else { continue }
                    phase = .ready
                case .awaitingBaseline:
                    phase = .ready
                    if case .cachedBaseline = update.contents { queue.insert(contentsOf: fenced, at: 0) }
                    fenced.removeAll()
                case .ready: break
                }
                publish(contacts)
                if case let .readback(id) = update.origin { resolve(id, result: .success(contacts)) }
                for (id, request) in readbacks where request.requestTask == nil {
                    startReadback(id)
                }
            } catch {
                handleApplyFailure(error, update: update)
            }
        }
    }

    private func handleApplyFailure(_ error: any Error, update: RosterUpdate) {
        guard !Task.isCancelled else { return }
        if case let .readback(id) = update.origin { resolve(id, result: .failure(error)) }
        if case .cachedBaseline = update.contents {
            degrade()
        } else if recoveryUsed {
            degrade()
        } else {
            recoveryUsed = true
            beginReconciliation()
        }
    }

    private func beginReconciliation() {
        let id = UUID().uuidString
        phase = .recovering(id)
        baselineAdmitted = false
        queue.removeAll()
        fenced.removeAll()
        for (requestID, request) in readbacks where request.requestTask != nil {
            resolve(requestID, result: .failure(Failure.degraded))
        }
        recoveryTask?.cancel()
        recoveryTask = ownTask { [weak self, client] in
            do {
                try await Self.requestReadback(id: id, client: client)
            } catch {
                guard let self, case let .recovering(currentID) = phase, currentID == id else { return }
                degrade()
            }
        }
    }

    private func degrade() {
        phase = .degraded
        queue.removeAll()
        fenced.removeAll()
        recoveryTask?.cancel()
        for id in readbacks.keys {
            resolve(id, result: .failure(Failure.degraded))
        }
        for id in commands.keys {
            resolveCommand(id)
        }
    }

    private func ownTask(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { [weak self] in
            await operation()
            self?.ownedTasks[id] = nil
        }
        ownedTasks[id] = task
        return task
    }

    func end() -> [Task<Void, Never>] {
        phase = .ended
        queue.removeAll()
        fenced.removeAll()
        let tasks = Array(ownedTasks.values)
        for task in tasks {
            task.cancel()
        }
        for id in commands.keys {
            resolveCommand(id)
        }
        for id in readbacks.keys {
            resolve(id, result: .failure(Failure.ended))
        }
        worker = nil
        recoveryTask = nil
        return tasks
    }
}
