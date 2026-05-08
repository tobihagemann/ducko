import DuckoXMPP
import Foundation

/// Per-account waiter registry for `XMPPEvent` dispatch in integration tests.
///
/// Stores `Waiter` closure-bundles keyed by `(accountID, waiterID)`. Each
/// `waitForEvent` / `collectEvents` call on `ConnectedAccount` allocates a
/// fresh `UUID`, installs a waiter via `register`, and either resolves on a
/// matching dispatch or unwinds via `cancelWaiter` (timeout, caller
/// `Task.cancel`, harness teardown).
///
/// Three load-bearing invariants the design depends on:
///
/// 1. **`dispatch` is reached from MainActor-synchronous call sites.** The
///    harness's `onExternalEvent` `@Sendable` closure hops onto the main actor
///    via `MainActor.assumeIsolated` before calling `dispatch`, so the
///    registry-mutation steps in `dispatch` / `register` / `cancelWaiter` are
///    mutually serialized on the MainActor queue. `dispatch` itself defers
///    waiter delivery to a fresh `Task { @MainActor in … }` (so domain-service
///    Tasks get a chance to handle the event before the test coroutine
///    resumes), but that deferred Task re-checks `waiters[accountID]?[id]` as
///    the source of truth before calling `deliver` — so a waiter resolved or
///    cancelled between the snapshot and the deferred run never gets a second
///    resume. Any future async event source that bypasses the synchronous
///    `dispatch` entry would silently break the snapshot's race-freedom
///    argument — keep `dispatch` reachable only from MainActor-synchronous
///    call sites.
/// 2. **Broadcast to all active waiters; FIFO gap buffer when none are
///    active.** When at least one waiter is registered for the account, every
///    active waiter sees the event and each whose `deliver` returns `true`
///    consumes its own copy; declines are dropped. Each waiter is one-shot,
///    so a single dispatched event resolves at most one resume per waiter.
///    When no waiter is active, the event is appended to a per-account FIFO
///    replay log so that a waiter registered AFTER the emitting `await`
///    returned still sees it. The next `register` drains the log
///    consume-on-iterate — every event is delivered to that one new waiter
///    exactly once, regardless of whether it consumed or declined.
/// 3. **Tombstone consumes atomically inside `register`.** If a caller's
///    `Task.cancel()` reaches `cancelWaiter` BEFORE `register` runs, the
///    cancel stamps a tombstone for that waiter id; `register` checks the
///    tombstone as its first action and routes through the supplied `cancel`
///    closure (resume-throw `.streamClosed`) without ever installing the
///    waiter. Single-resume invariant per wait, even under the install-vs-
///    cancel race.
@MainActor
final class EventRouter {
    private struct Waiter {
        let id: UUID
        let deliver: @MainActor (XMPPEvent) -> Bool
        let cancel: @MainActor (TestHarnessError) -> Void
        let timeoutTask: Task<Void, Never>
    }

    /// Active waiters, keyed by `accountID` then by waiter `id`. Nested-dict
    /// shape mirrors `ChatService.roomJoinNotifiers` keying.
    private var waiters: [UUID: [UUID: Waiter]] = [:]

    /// Per-account FIFO gap buffer: events that arrived while no waiter was
    /// registered for the account. Drained consume-on-iterate by the next
    /// `register` call.
    private var pendingEvents: [UUID: [XMPPEvent]] = [:]

    /// Cancellation tombstones for the install-vs-cancel race. A waiter id
    /// lands here when `cancelWaiter` runs before `register` for the same id;
    /// `register` consumes the tombstone atomically at entry.
    private var cancelledWaiterIDs: Set<UUID> = []

    /// Registers a waiter for `accountID` under `id`. The caller supplies the
    /// id so a `withTaskCancellationHandler` `onCancel:` closure can reference
    /// it before `register` runs (eliminates the install-vs-cancel race that
    /// an internally-generated id would re-introduce).
    ///
    /// Order of operations:
    /// 1. Atomically consume a tombstone for `id`. If present (cancel arrived
    ///    first), invoke `cancel(.streamClosed)` and return — the waiter is
    ///    never installed.
    /// 2. Build the per-waiter timeout `Task<Void, Never>`.
    /// 3. Insert the `Waiter` into `waiters[accountID]`.
    /// 4. Drain `pendingEvents[accountID]` consume-on-iterate, popping events
    ///    off the front and offering each to `deliver`. The first to return
    ///    `true` resolves the waiter (remove it, cancel its timeout, stop).
    ///    Declines are dropped.
    func register(
        accountID: UUID,
        id: UUID,
        deliver: @escaping @MainActor (XMPPEvent) -> Bool,
        cancel: @escaping @MainActor (TestHarnessError) -> Void,
        timeout: Duration
    ) {
        if cancelledWaiterIDs.remove(id) != nil {
            cancel(.streamClosed)
            return
        }

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.cancelWaiter(accountID: accountID, id: id, error: .timeout)
        }

        let waiter = Waiter(id: id, deliver: deliver, cancel: cancel, timeoutTask: timeoutTask)
        waiters[accountID, default: [:]][id] = waiter

        guard var queue = pendingEvents[accountID], !queue.isEmpty else { return }
        while !queue.isEmpty {
            let event = queue.removeFirst()
            if deliver(event) {
                waiters[accountID]?.removeValue(forKey: id)
                if waiters[accountID]?.isEmpty == true {
                    waiters.removeValue(forKey: accountID)
                }
                timeoutTask.cancel()
                pendingEvents[accountID] = queue.isEmpty ? nil : queue
                return
            }
        }
        pendingEvents[accountID] = nil
    }

    /// Cancels the waiter `(accountID, id)` if installed, or stamps a
    /// tombstone if not yet installed. Every call site supplies `error`
    /// explicitly so a forgotten argument cannot silently downgrade
    /// `.streamClosed` to `.timeout`.
    ///
    /// If the waiter is installed: remove it, cancel its `timeoutTask`, call
    /// its `cancel(error)`. If missing: insert `id` into `cancelledWaiterIDs`.
    /// The next `register` for that `id` consumes the tombstone atomically
    /// and routes through the supplied `cancel` closure.
    ///
    /// Accepted bounded leak: a queued `onCancel:` hop can race AFTER the
    /// waiter resolved-and-was-removed (caller-cancel arrives just after
    /// dispatch). `cancelWaiter` finds no entry and stamps a tombstone for an
    /// id that no `register` will ever consume — UUIDs are unique per call so
    /// the stale tombstone cannot accidentally satisfy a future install-vs-
    /// cancel check, and `cancelAllWaiters` clears the set on teardown.
    func cancelWaiter(accountID: UUID, id: UUID, error: TestHarnessError) {
        if let waiter = waiters[accountID]?.removeValue(forKey: id) {
            if waiters[accountID]?.isEmpty == true {
                waiters.removeValue(forKey: accountID)
            }
            waiter.timeoutTask.cancel()
            waiter.cancel(error)
            return
        }
        cancelledWaiterIDs.insert(id)
    }

    /// Routes `event` to every active waiter for `accountID`. Each waiter
    /// whose `deliver` returns `true` consumes the event and is removed from
    /// the registry; declines are dropped. Waiters are one-shot, so a single
    /// dispatched event resumes each matching waiter at most once.
    ///
    /// When no waiters are active for `accountID`, appends `event` to the
    /// per-account FIFO gap buffer. The next `register` for that `accountID`
    /// drains the buffer consume-on-iterate.
    func dispatch(_ event: XMPPEvent, accountID: UUID) {
        // Defer waiter resumption to a fresh MainActor task so AppEnvironment's
        // domain-service `Task { @MainActor in ... }` (chatService, omemoService,
        // etc.) gets a chance to handle the event BEFORE the test coroutine
        // resumes from the awaited `waitForEvent`. With the old shared
        // AsyncStream, the AsyncStream iterator's `next()` suspension/resume
        // dance happened to interleave with the domain services Task; this hop
        // restores that interleaving for the new continuation-based path.
        // Otherwise tests like OMEMOTests's "Service encrypted send persists"
        // race past the domain-side persist and time out their waitForCondition
        // poll.
        //
        // The deferred Task re-checks `waiters[accountID]?[id]` before calling
        // `deliver` so a waiter resolved or cancelled between snapshot and run
        // (e.g. by an earlier deferred Task, a `cancelWaiter(.timeout)`, or
        // `cancelAllWaiters`) is not delivered a second time — `deliver`
        // resuming an already-resumed `CheckedContinuation` would trap.
        if let bucket = waiters[accountID], !bucket.isEmpty {
            let snapshot = bucket
            Task { @MainActor in
                for (id, waiter) in snapshot
                    where self.waiters[accountID]?[id] != nil && waiter.deliver(event) {
                    self.waiters[accountID]?.removeValue(forKey: id)
                    waiter.timeoutTask.cancel()
                }
                if self.waiters[accountID]?.isEmpty == true {
                    self.waiters.removeValue(forKey: accountID)
                }
            }
            return
        }
        pendingEvents[accountID, default: []].append(event)
    }

    /// Drains every waiter across every account, cancelling each timeout
    /// task and resuming each `cancel` closure with `.streamClosed`. Order
    /// matches `XMPPClient.cleanUp`'s `pendingIQs`-drain block: snapshot,
    /// clear, then iterate. Also clears `pendingEvents` and
    /// `cancelledWaiterIDs` so a re-used router (same harness instance)
    /// starts clean.
    func cancelAllWaiters() {
        let snapshot = waiters
        waiters.removeAll()
        for bucket in snapshot.values {
            for waiter in bucket.values {
                waiter.timeoutTask.cancel()
                waiter.cancel(.streamClosed)
            }
        }
        pendingEvents.removeAll()
        cancelledWaiterIDs.removeAll()
    }

    /// Test-only seam for deterministic install-observation in
    /// `EventRouterTests`. Plain `internal`, reachable from siblings in the
    /// same target.
    func pendingWaiterCount(forAccountID accountID: UUID) -> Int {
        waiters[accountID]?.count ?? 0
    }
}
